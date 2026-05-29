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
    /// Monotonic child-generation counter. Bumped on every spawn/respawn/close so a
    /// stale `watchForExit`/read-source from a prior generation (e.g. the shell we just
    /// SIGTERM'd during a respawn) bails out instead of tearing down — or firing
    /// `onExit` for — the child that replaced it. The previous code let the old
    /// exit-watcher's `close()` kill the freshly respawned shell.
    private var generation: UInt64 = 0
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

    /// Extra environment injected into the child shell on spawn *and* respawn
    /// (Harness-owned `$HARNESS`/`$HARNESS_SURFACE` plus user `set-environment`).
    private let extraEnvironment: [String: String]

    public init(
        id: DaemonSurfaceID,
        cwd: String,
        shell: String,
        rows: UInt16 = 24,
        cols: UInt16 = 80,
        scrollbackBytes: Int = 1024 * 1024,
        extraEnvironment: [String: String] = [:]
    ) throws {
        self.id = id
        self.maxScrollbackBytes = scrollbackBytes
        self.extraEnvironment = extraEnvironment

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
        for (key, value) in extraEnvironment { environment[key] = value }
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
        lifecycleLock.lock()
        generation &+= 1
        let gen = generation
        self.master = amaster
        self.childPID = pid
        lifecycleLock.unlock()
        AgentDetector.registerRootPID(pid, forSurfaceKey: id)
        startReading(fd: amaster, generation: gen)
        watchForExit(pid: pid, generation: gen)
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

    /// Terminate the child shell and respawn a new one with the same surface
    /// ID, same env, same cwd. The scrollback is preserved unless
    /// `clearHistory` is true — letting users either keep their context or
    /// start clean depending on intent. Surface subscribers keep their
    /// subscription (it's keyed by surface ID, not shell PID), so the GUI and
    /// any `harness-cli attach` simply see fresh output begin.
    public func respawn(clearHistory: Bool) {
        lifecycleLock.lock()
        let oldPID = childPID
        let oldFD = master
        let oldSource = readSource
        let oldRows: UInt16
        let oldCols: UInt16
        var winsize = Darwin.winsize()
        if oldFD >= 0, ioctl(oldFD, TIOCGWINSZ, &winsize) == 0 {
            oldRows = winsize.ws_row
            oldCols = winsize.ws_col
        } else {
            oldRows = 24
            oldCols = 80
        }
        // Advance the generation so the old child's exit-watcher and read-source
        // recognise they've been superseded and bail (instead of running close()/
        // onExit against the shell we're about to spawn).
        generation &+= 1
        readSource = nil
        master = -1
        childPID = -1
        isClosed = false
        lifecycleLock.unlock()

        if oldPID > 0 { kill(oldPID, SIGTERM) }
        if let oldSource {
            oldSource.cancel()
        } else if oldFD >= 0 {
            Darwin.close(oldFD)
        }
        if clearHistory {
            scrollbackLock.lock()
            scrollback.removeAll()
            scrollbackBytes = 0
            nextSequence = 1
            scrollbackLock.unlock()
        }
        // Spawn a new shell, reusing the cwd of the previous process if we can
        // still read it from the dead PID's last-known location, otherwise the
        // home directory.
        let cwd = Self.cwd(for: oldPID) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        do {
            try restartChild(cwd: cwd, shell: shell, rows: oldRows, cols: oldCols)
        } catch {
            fputs("HarnessDaemon: respawn failed for \(id): \(error)\n", stderr)
        }
    }

    private func restartChild(cwd: String, shell: String, rows: UInt16, cols: UInt16) throws {
        let argvStrings = ShellLaunchProfile.make(shell: shell).argv
        let argv: [UnsafeMutablePointer<CChar>?] = argvStrings.map { strdup($0) } + [nil]

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["HARNESS_SURFACE"] = id
        for (key, value) in extraEnvironment { environment[key] = value }
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
        freeChildStrings()
        lifecycleLock.lock()
        generation &+= 1
        let gen = generation
        self.master = amaster
        self.childPID = pid
        lifecycleLock.unlock()
        AgentDetector.registerRootPID(pid, forSurfaceKey: id)
        startReading(fd: amaster, generation: gen)
        watchForExit(pid: pid, generation: gen)
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
        generation &+= 1
        let pid = childPID
        let source = readSource
        let fd = master
        readSource = nil
        master = -1
        childPID = -1
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

    public var scrollbackByteCount: Int {
        scrollbackLock.lock()
        defer { scrollbackLock.unlock() }
        return scrollbackBytes
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

    /// `capture-pane -S <start> -E <end> -p`: ANSI-stripped display lines in the
    /// given range. Negative indices count back from the last line (tmux semantics);
    /// nil start = first line, nil end = last line.
    public func captureRange(start: Int?, end: Int?) -> String {
        let stripped = Self.stripANSI(captureScrollback(includeHistory: true))
        var lines = stripped.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let count = lines.count
        guard count > 0 else { return "" }
        func resolve(_ value: Int?, fallback: Int) -> Int {
            guard let value else { return fallback }
            return value < 0 ? max(0, count + value) : min(value, count - 1)
        }
        let lo = resolve(start, fallback: 0)
        let hi = resolve(end, fallback: count - 1)
        guard lo <= hi else { return "" }
        return lines[lo ... hi].joined(separator: "\n")
    }

    /// Strip CSI/OSC escape sequences and stray control bytes (keeping `\n`/`\t`)
    /// so captured scrollback is plain text.
    static func stripANSI(_ input: String) -> String {
        var out = String()
        out.reserveCapacity(input.count)
        let buffer = Array(input.unicodeScalars)
        var i = 0
        while i < buffer.count {
            let scalar = buffer[i]
            if scalar == "\u{1b}" { // ESC
                let next = i + 1 < buffer.count ? buffer[i + 1] : nil
                if next == "[" { // CSI … final byte 0x40–0x7e
                    i += 2
                    while i < buffer.count, !(buffer[i].value >= 0x40 && buffer[i].value <= 0x7e) { i += 1 }
                    i += 1
                    continue
                } else if next == "]" { // OSC … terminated by BEL or ESC \
                    i += 2
                    while i < buffer.count {
                        if buffer[i] == "\u{07}" { i += 1; break }
                        if buffer[i] == "\u{1b}", i + 1 < buffer.count, buffer[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                    continue
                } else {
                    i += 2 // ESC + one byte (e.g. charset select)
                    continue
                }
            }
            if scalar.value < 0x20, scalar != "\n", scalar != "\t" { i += 1; continue }
            out.unicodeScalars.append(scalar)
            i += 1
        }
        return out
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

    private func startReading(fd: Int32, generation gen: UInt64) {
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8 * 1024)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n <= 0 {
                // EOF / error: the shell for this generation ended.
                self.childEnded(generation: gen)
                return
            }
            let data = Data(buffer.prefix(n))
            self.handleOutput(data)
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        // Install only if we're still the current generation; a concurrent
        // respawn/close may have already advanced past us, in which case cancel
        // (which closes fd) rather than leaking a live source on a dead surface.
        lifecycleLock.lock()
        if generation == gen, !isClosed {
            readSource = source
            lifecycleLock.unlock()
            source.resume()
        } else {
            lifecycleLock.unlock()
            source.cancel()
        }
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

    private func watchForExit(pid: pid_t, generation gen: UInt64) {
        DispatchQueue.global().async { [weak self] in
            guard let self, pid > 0 else { return }
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            self.childEnded(generation: gen)
        }
    }

    /// Called when a child for generation `gen` ends (read EOF or `waitpid`
    /// returning). Tears down + fires `onExit` exactly once, and only if `gen` is
    /// still current — a respawn/close that advanced the generation means this is a
    /// superseded child whose death must NOT touch the live one. The EOF path and
    /// the `waitpid` path both call this; the `isClosed` guard makes the second a
    /// no-op so `onExit` fires once.
    private func childEnded(generation gen: UInt64) {
        lifecycleLock.lock()
        guard generation == gen, !isClosed else {
            lifecycleLock.unlock()
            return
        }
        isClosed = true
        generation &+= 1
        let source = readSource
        let fd = master
        readSource = nil
        master = -1
        childPID = -1
        lifecycleLock.unlock()

        AgentDetector.unregisterRootPID(forSurfaceKey: id)
        if let source {
            source.cancel()
        } else if fd >= 0 {
            Darwin.close(fd)
        }
        onExit?()
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
