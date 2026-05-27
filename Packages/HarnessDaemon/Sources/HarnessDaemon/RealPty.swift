import Darwin
import Foundation
import HarnessCore

/// PTY-backed shell session. Replaces `Process`-based `PtySession` with a
/// genuine `forkpty(3)` master fd so the daemon can keep a long-lived
/// terminal alive across app detach/reattach cycles.
///
/// Public API mirrors `PtySession` so call sites can switch implementations
/// transparently. Phase 5b plumbs this into the IPC subscription stream.
public final class RealPty: @unchecked Sendable {
    public let id: DaemonSurfaceID

    private var master: Int32 = -1
    private var childPID: pid_t = -1

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

        var winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var amaster: Int32 = -1
        let pid = forkpty(&amaster, nil, nil, &winsize)
        if pid < 0 {
            throw PtyError.launchFailed
        }
        if pid == 0 {
            // Child branch — exec the login shell. NEVER return; if exec fails we _exit.
            let cwdC = strdup(cwd)
            if let cwdC { _ = chdir(cwdC); free(cwdC) }
            setenv("TERM", "xterm-256color", 1)
            setenv("HARNESS_SURFACE", id, 1)
            let shellName = URL(fileURLWithPath: shell).lastPathComponent
            shell.withCString { shellPtr in
                let arg0 = strdup(shellPtr)
                let loginArg = strdup("-l")
                var argv: [UnsafeMutablePointer<CChar>?]
                if shellName == "fish" {
                    let featureArg = strdup("--features=no-query-term")
                    argv = [arg0, featureArg, loginArg, nil]
                } else {
                    argv = [arg0, loginArg, nil]
                }
                _ = argv.withUnsafeMutableBufferPointer { buf in
                    execv(shellPtr, buf.baseAddress)
                }
            }
            _exit(127)
        }
        self.master = amaster
        self.childPID = pid
        AgentDetector.registerRootPID(pid, forSurfaceKey: id)
        startReading()
        watchForExit()
    }

    public func write(_ data: Data) {
        guard master >= 0 else { return }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let result = Darwin.write(master, base.advanced(by: written), buffer.count - written)
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
        guard master >= 0 else { return }
        var winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &winsize)
    }

    public func currentWorkingDirectory() -> String? {
        Self.cwd(for: deepestReadableDescendant(of: childPID) ?? childPID)
    }

    public func close() {
        if childPID > 0 {
            kill(childPID, SIGTERM)
        }
        if master >= 0 {
            Darwin.close(master)
            master = -1
        }
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
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: readQueue)
        readSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8 * 1024)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(self.master, ptr.baseAddress, ptr.count)
            }
            if n <= 0 { return }
            let data = Data(buffer.prefix(n))
            self.handleOutput(data)
        }
        source.setCancelHandler {}
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
