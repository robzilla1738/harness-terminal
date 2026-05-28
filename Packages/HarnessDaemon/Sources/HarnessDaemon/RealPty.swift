import Darwin
import Foundation
import HarnessCore

public enum PtyError: Error {
    case launchFailed
}

public struct ShellLaunchProfile: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]

    public var argv: [String] { [executable] + arguments }

    public static func make(shell: String) -> ShellLaunchProfile {
        let name = URL(fileURLWithPath: shell).lastPathComponent.lowercased()
        let arguments: [String]
        switch name {
        case "fish":
            arguments = ["--features=no-query-term", "-l"]
        case "zsh", "bash", "sh", "dash", "ksh", "csh", "tcsh":
            arguments = ["-l"]
        case "nu":
            arguments = ["--login"]
        case "pwsh", "powershell":
            arguments = ["-Login"]
        case "xonsh":
            arguments = ["--login"]
        default:
            // Unknown shells should still launch out of the box. Avoid adding a
            // guessed login flag that could make custom shells exit immediately.
            arguments = []
        }
        return ShellLaunchProfile(executable: shell, arguments: arguments)
    }
}

/// PTY-backed shell session built on a genuine `forkpty(3)` master fd so the daemon
/// can keep a long-lived terminal alive across app detach/reattach cycles. Output is
/// fanned to a scrollback ring buffer and to live subscribers (the running app plus
/// any `harness-cli attach` clients).
///
/// @unchecked Sendable: mutable state is partitioned across three locks —
/// `lifecycleLock` (master fd, childPID, isClosed, readSource), `scrollbackLock`
/// (scrollback buffer + sequence counter), and `subscribersLock` (subscriber table).
public final class RealPty: @unchecked Sendable {
    public let id: DaemonSurfaceID

    private var master: Int32 = -1
    private var childPID: pid_t = -1
    private var isClosed = false
    private let lifecycleLock = NSLock()

    private let readQueue = DispatchQueue(label: "com.robert.harness.realpty.read")
    private var readSource: DispatchSourceRead?

    public var onOutput: ((Data) -> Void)?
    public var onExit: (() -> Void)?

    /// Append-only ring buffer of terminal output bytes. Indexed by sequence
    /// number so reattaching clients can request "give me everything since N".
    private struct ScrollbackEntry {
        let sequence: UInt64
        let data: Data
    }
    private var scrollback: [ScrollbackEntry] = []
    private var scrollbackBytes: Int = 0
    private var maxScrollbackBytes: Int
    private var nextSequence: UInt64 = 1
    private let scrollbackLock = NSLock()

    /// Subscribers receive raw output. Multiple subscribers can attach (the
    /// running app + any number of `harness-cli attach` clients).
    private var subscribers: [UUID: (Data, UInt64) -> Void] = [:]
    private let subscribersLock = NSLock()

    public init(
        id: DaemonSurfaceID,
        cwd: String,
        shell: String,
        rows: UInt16 = 24,
        cols: UInt16 = 80,
        scrollbackBytes: Int = 1024 * 1024
    ) throws {
        self.id = id
        self.maxScrollbackBytes = scrollbackBytes

        // Prepare everything the child needs BEFORE forking. Between fork and exec a
        // child may only call async-signal-safe functions, so it must not malloc —
        // `setenv`/`strdup` do. We build argv + a full envp here (parent side) and the
        // child only calls `chdir` + `execve`, both async-signal-safe. (Doing this in
        // the child is what made the PTY fragile under heavily-threaded callers.)
        let argvStrings = ShellLaunchProfile.make(shell: shell).argv
        let argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["HARNESS_SURFACE"] = id
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]

        let cwdC = strdup(cwd)
        func freeChildStrings() {
            cwdC.map { free($0) }
            argv.forEach { $0.map { free($0) } }
            envp.forEach { $0.map { free($0) } }
        }

        var winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var amaster: Int32 = -1
        let pid = forkpty(&amaster, nil, nil, &winsize)
        if pid < 0 {
            freeChildStrings()
            throw PtyError.launchFailed
        }
        if pid == 0 {
            // Child branch — async-signal-safe only. NEVER return; if exec fails, _exit.
            if let cwdC { _ = chdir(cwdC) }
            argv.withUnsafeBufferPointer { argvBuffer in
                envp.withUnsafeBufferPointer { envpBuffer in
                    if let path = argvBuffer.baseAddress?.pointee {
                        _ = execve(path, argvBuffer.baseAddress, envpBuffer.baseAddress)
                    }
                }
            }
            _exit(127)
        }
        // Parent: the child holds its own copy-on-write view; free ours.
        freeChildStrings()
        self.master = amaster
        self.childPID = pid
        AgentDetector.registerRootPID(pid, forSurfaceKey: id)
        startReading()
        watchForExit()
    }

    public func write(_ data: Data) {
        lifecycleLock.lock()
        let fd = master
        lifecycleLock.unlock()
        guard fd >= 0 else { return }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(fd, base.advanced(by: written), buffer.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    break
                }
                written += result
            }
        }
    }

    public func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        write(data)
    }

    public func resize(rows: UInt16, cols: UInt16) {
        lifecycleLock.lock()
        let fd = master
        lifecycleLock.unlock()
        guard fd >= 0 else { return }
        var winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(fd, TIOCSWINSZ, &winsize)
    }

    public func currentWorkingDirectory() -> String? {
        Self.cwd(for: deepestReadableDescendant(of: childPID) ?? childPID)
    }

    public func close() {
        lifecycleLock.lock()
        guard !isClosed else {
            lifecycleLock.unlock()
            return
        }
        isClosed = true
        let pid = childPID
        let source = readSource
        let fd = master
        readSource = nil
        master = -1
        lifecycleLock.unlock()

        AgentDetector.unregisterRootPID(forSurfaceKey: id)
        if pid > 0 { kill(pid, SIGTERM) }
        if let source {
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
    }

    deinit {
        // Backstop: if a surface is dropped without an explicit close() (e.g. a
        // dictionary entry overwritten), reap the child + fd so we never leak a
        // zombie. close() is idempotent via the isClosed guard.
        close()
    }

    public func captureScrollback(includeHistory: Bool) -> String {
        scrollbackLock.lock()
        let combined: Data
        if includeHistory {
            combined = scrollback.reduce(into: Data()) { $0.append($1.data) }
        } else {
            // Tail roughly the last 16 KiB.
            var tail = Data()
            for entry in scrollback.reversed() {
                tail.insert(contentsOf: entry.data, at: 0)
                if tail.count >= 16 * 1024 { break }
            }
            combined = tail
        }
        scrollbackLock.unlock()
        return String(data: combined, encoding: .utf8) ?? ""
    }

    public func replay(fromSequence: UInt64?) -> String {
        scrollbackLock.lock()
        let entries: [ScrollbackEntry]
        if let from = fromSequence {
            entries = scrollback.filter { $0.sequence >= from }
        } else {
            entries = scrollback
        }
        scrollbackLock.unlock()
        let combined = entries.reduce(into: Data()) { $0.append($1.data) }
        return String(data: combined, encoding: .utf8) ?? ""
    }

    public func subscribe(_ handler: @escaping (Data, UInt64) -> Void) -> UUID {
        let token = UUID()
        subscribersLock.lock()
        subscribers[token] = handler
        subscribersLock.unlock()
        return token
    }

    public func cancelSubscription(token: UUID? = nil) {
        subscribersLock.lock()
        if let token { subscribers.removeValue(forKey: token) } else { subscribers.removeAll() }
        subscribersLock.unlock()
    }

    public func detachSubscriber(token: UUID? = nil) {
        cancelSubscription(token: token)
    }

    private func startReading() {
        lifecycleLock.lock()
        let fd = master
        lifecycleLock.unlock()
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        readSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8 * 1024)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 {
                self.close()
                return
            }
            let data = Data(buffer.prefix(n))
            self.handleOutput(data)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
    }

    private func handleOutput(_ data: Data) {
        scrollbackLock.lock()
        let sequence = nextSequence
        nextSequence &+= UInt64(data.count)
        scrollback.append(ScrollbackEntry(sequence: sequence, data: data))
        scrollbackBytes += data.count
        while scrollbackBytes > maxScrollbackBytes, let first = scrollback.first {
            scrollbackBytes -= first.data.count
            scrollback.removeFirst()
        }
        scrollbackLock.unlock()

        AgentDetector.recordActivity(forSurfaceKey: id)
        onOutput?(data)

        subscribersLock.lock()
        let handlers = Array(subscribers.values)
        subscribersLock.unlock()
        for handler in handlers { handler(data, sequence) }
    }

    private func watchForExit() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            _ = waitpid(self.childPID, &status, 0)
            self.close()
            self.onExit?()
        }
    }

    private func deepestReadableDescendant(of pid: pid_t) -> pid_t? {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { return nil }
        let bufferCount = Int(count) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: bufferCount)
        let bytes = proc_listpids(
            UInt32(PROC_ALL_PIDS),
            0,
            &pids,
            Int32(MemoryLayout<pid_t>.size * bufferCount)
        )
        let actual = Int(bytes) / MemoryLayout<pid_t>.size
        let all = pids.prefix(actual).filter { $0 > 0 }
        var parents: [pid_t: pid_t] = [:]
        for candidate in all { parents[candidate] = Self.parentPID(candidate) }

        var best: (pid: pid_t, depth: Int)?
        for candidate in all where candidate != pid {
            var cursor = candidate
            var depth = 0
            while let parent = parents[cursor], parent != 0, depth < 32 {
                depth += 1
                if parent == pid {
                    if Self.cwd(for: candidate) != nil, best == nil || depth > best!.depth {
                        best = (candidate, depth)
                    }
                    break
                }
                cursor = parent
            }
        }
        return best?.pid
    }

    private static func parentPID(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard bytes == size else { return 0 }
        return pid_t(info.pbi_ppid)
    }

    private static func cwd(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard bytes == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }
}
