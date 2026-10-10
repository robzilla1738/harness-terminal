import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SSHTunnelError: Error, CustomStringConvertible {
    case launchFailed(String)
    case invalidConfiguration(String)
    case notReady(host: String)
    /// The `ssh` process exited before the tunnel became reachable — almost always a bad host,
    /// bad credentials, or a refused forward, NOT a slow remote. Carries the exit status so the
    /// message can point at the real cause instead of looking like a generic timeout.
    case exitedEarly(host: String, status: Int32)
    /// ssh exited early and its stderr named a cause a person can act on.
    case rejected(host: String, reason: String)

    public var description: String {
        switch self {
        case let .launchFailed(message): return "Failed to start SSH tunnel: \(message)"
        case let .invalidConfiguration(message): return "Invalid SSH tunnel configuration: \(message)"
        case let .notReady(host): return "SSH tunnel to '\(host)' did not become ready in time"
        case let .exitedEarly(host, status):
            return "ssh exited with status \(status) before the tunnel to '\(host)' became ready "
                + "— check the host, credentials, and remote socket path"
        case let .rejected(host, reason): return "Can't reach '\(host)': \(reason)"
        }
    }
}

/// Manages SSH tunnels that forward a remote daemon's Unix control socket to a local socket, so the
/// existing `DaemonClient`/`DaemonSubscription` (which speak length-prefixed frames over any byte
/// stream) can drive a remote Harness daemon unchanged. This remote transport
/// reuses the user's existing SSH trust for both encryption and authentication, with no new crypto.
///
/// One `ssh -N -L <local>:<remote>` process per host; `endpoint(for:)` ensures it's up (re-spawning
/// if it died) and returns the local `.unix` endpoint to connect to. @unchecked Sendable: the tunnel
/// table is guarded by `lock`.
public final class SSHTunnelManager: @unchecked Sendable {
    public static let shared = SSHTunnelManager()

    /// Drain diagnostics for the child's whole lifetime without persistent host data
    /// or an unbounded file. Keep only a bounded tail for actionable early failures.
    private final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private var tail = Data()
        private let pipe: Pipe
        init(_ pipe: Pipe) {
            self.pipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil; return }
                guard let self else { return }
                self.lock.lock()
                self.tail.append(bytes.suffix(64 * 1024))
                if self.tail.count > 64 * 1024 { self.tail = Data(self.tail.suffix(64 * 1024)) }
                self.lock.unlock()
            }
        }
        var reason: String? {
            lock.lock(); let snapshot = tail; lock.unlock()
            return SSHTunnelManager.diagnose(String(decoding: snapshot, as: UTF8.self))
        }
        deinit { pipe.fileHandleForReading.readabilityHandler = nil; try? pipe.fileHandleForReading.close() }
    }

    private final class Tunnel {
        let process: Process
        let localSocket: URL
        let diagnostics: Diagnostics?
        init(process: Process, localSocket: URL, diagnostics: Diagnostics?) {
            self.process = process
            self.localSocket = localSocket
            self.diagnostics = diagnostics
        }
    }

    private let lock = NSLock()
    private var tunnels: [String: Tunnel] = [:]
    private final class OperationGate { let lock = NSLock(); var users = 0 }
    private struct PreviewKey: Hashable { var host: String; var surface: UUID }
    private struct PreviewForward { var process: Process; var port: Int; var remoteAddress: String; var remotePort: Int; var token: UUID }
    private var previews: [PreviewKey: PreviewForward] = [:]
    private var previewLocks: [PreviewKey: OperationGate] = [:]
    private let previewSlots = DispatchSemaphore(value: 16)
    private var hostEpochs: [String: UInt64] = [:]

    /// Hosts whose `ssh` exit is this manager calling `stop`, not a dropped tunnel.
    private var endpointLocks: [String: OperationGate] = [:]
    /// Whether the process-exit cleanup hook has been installed (guarded by `lock`).
    private var exitCleanupRegistered = false
    /// Fired when an `ssh` forward exits on its own. The app publishes `client.connection`.
    public var onTunnelDropped: (@Sendable (String) -> Void)?

    /// Builds the (not-yet-started) `ssh -N -L …` child for a host. Injectable purely so tests can
    /// drive the lifecycle/failure paths with a controllable child instead of a real `ssh`; the
    /// production default below is the only value any shipping caller ever uses.
    private let makeTunnelProcess: (RemoteHost, URL) throws -> Process
    /// Probes whether the forwarded local socket reaches a live remote daemon (a `ping`→`pong`).
    /// Injectable for the same test-only reason; the production default is the real daemon probe.
    private let makePreviewProcess: (RemoteHost, Int, String, Int) throws -> Process
    private let reachabilityProbe: (Endpoint) -> Bool

    public convenience init() {
        self.init(makeTunnelProcess: nil, reachabilityProbe: nil)
    }

    /// Test seam: `makeTunnelProcess`/`reachabilityProbe` default to the production builders when
    /// nil, so this is behaviourally identical to `init()` for every shipping caller. Tests inject
    /// closures to characterize the lifecycle and failure modes without spawning real `ssh`.
    init(
        makeTunnelProcess: ((RemoteHost, URL) throws -> Process)?,
        reachabilityProbe: ((Endpoint) -> Bool)?,
        makePreviewProcess: ((RemoteHost, Int, String, Int) throws -> Process)? = nil
    ) {
        self.makeTunnelProcess = makeTunnelProcess ?? SSHTunnelManager.defaultTunnelProcess
        self.makePreviewProcess = makePreviewProcess ?? Self.defaultPreviewProcess
        self.reachabilityProbe = reachabilityProbe ?? SSHTunnelManager.defaultReachabilityProbe
    }

    /// Ensure a tunnel to `host` is running, then return the local endpoint that reaches the remote
    /// daemon. Reuses a live tunnel; (re)spawns one if absent or dead. Blocks until the remote
    /// daemon answers a `ping` over the tunnel, or throws after `waitTimeout`.
    public func endpoint(for host: RemoteHost, waitTimeout: TimeInterval = 10, expectedEpoch: UInt64? = nil) throws -> Endpoint {
        let deadline = Date().addingTimeInterval(max(0.05, min(waitTimeout, 30)))
        lock.lock()
        guard endpointLocks[host.name] != nil || endpointLocks.count < 64 else { lock.unlock(); throw SSHTunnelError.invalidConfiguration("Too many host connection identities in this process.") }
        let gate = endpointLocks[host.name] ?? OperationGate(); endpointLocks[host.name] = gate; gate.users += 1
        let operationLock = gate.lock
        let epoch = expectedEpoch ?? hostEpochs[host.name, default: 0]
        lock.unlock()
        defer { lock.lock(); gate.users -= 1; if gate.users == 0 { endpointLocks.removeValue(forKey: host.name) }; lock.unlock() }
        while !operationLock.try() {
            guard Date() < deadline else { throw SSHTunnelError.notReady(host: host.name) }
            Thread.sleep(forTimeInterval: 0.025)
        }
        defer { operationLock.unlock() }
        let localSocket = HarnessPaths.tunnelSocketURL(forHost: host.name)
        let endpoint = Endpoint.unix(path: localSocket.path)
        lock.lock(); let prior = tunnels[host.name]; let cancelled = hostEpochs[host.name, default: 0] != epoch; lock.unlock()
        guard !cancelled else { throw SSHTunnelError.notReady(host: host.name) }
        if prior != nil || FileManager.default.fileExists(atPath: localSocket.path), reachabilityProbe(endpoint) { return endpoint }
        if let prior, !prior.process.isRunning {
            lock.lock(); if tunnels[host.name] === prior { tunnels.removeValue(forKey: host.name) }; lock.unlock()
            try? FileManager.default.removeItem(at: prior.localSocket)
        } else if prior == nil, FileManager.default.fileExists(atPath: localSocket.path) {
            // A failed probe cannot prove another process's forward is stale.
            throw SSHTunnelError.notReady(host: host.name)
        }
        if prior?.process.isRunning != true { try spawnTunnel(host: host, localSocket: localSocket, epoch: epoch) }
        while Date() < deadline {
            lock.lock(); let cancelled = hostEpochs[host.name, default: 0] != epoch; let process = tunnels[host.name]?.process; lock.unlock()
            guard !cancelled else { throw SSHTunnelError.notReady(host: host.name) }
            if reachabilityProbe(endpoint) { return endpoint }
            if process?.isRunning != true {
                let status = process?.terminationStatus ?? -1
                lock.lock(); let reason = tunnels[host.name]?.diagnostics?.reason; lock.unlock()
                if let reason { throw SSHTunnelError.rejected(host: host.name, reason: reason) }
                throw SSHTunnelError.exitedEarly(host: host.name, status: status)
            }
            // Small jitter prevents several host reconnect loops from aligning.
            Thread.sleep(forTimeInterval: Double.random(in: 0.12...0.18))
        }
        // Keep the SSH process and binding: a sleeping or slow daemon is not proof
        // that the transport failed. A later probe can reuse the same forward.
        throw SSHTunnelError.notReady(host: host.name)
    }

    /// Whether any process (the GUI, another CLI call) has a working forward for `name` right now.
    /// `isConnected` only knows this process's own tunnels.
    public static func isForwarding(_ name: String) -> Bool {
        let socket = HarnessPaths.tunnelSocketURL(forHost: name)
        guard FileManager.default.fileExists(atPath: socket.path) else { return false }
        return defaultReachabilityProbe(.unix(path: socket.path))
    }

    /// Whether a host currently has a live tunnel process.
    public func isConnected(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tunnels[name]?.process.isRunning ?? false
    }

    public func stop(host name: String) {
        lock.lock()
        hostEpochs[name, default: 0] &+= 1
        let forwardKeys = previews.keys.filter { $0.host == name }
        let forwardProcesses = forwardKeys.compactMap { previews.removeValue(forKey: $0)?.process }
        let tunnel = tunnels.removeValue(forKey: name)
        // Mark the exit as ours only when we're about to cause it. A process that already
        // exited won't report again, and a stale mark would swallow the next real drop.
        let running = tunnel?.process.isRunning ?? false
        lock.unlock()
        for process in forwardProcesses where process.isRunning { process.terminate() }
        guard let tunnel else { return }
        if running { tunnel.process.terminate() }
        try? FileManager.default.removeItem(at: tunnel.localSocket)
    }

    public func stopAll() {
        lock.lock()
        let all = tunnels
        for name in Set(tunnels.keys).union(hostEpochs.keys).union(previews.keys.map(\.host)) { hostEpochs[name, default: 0] &+= 1 }
        let forwardProcesses = previews.values.map(\.process); previews.removeAll()
        tunnels.removeAll()
        lock.unlock()
        for process in forwardProcesses where process.isRunning { process.terminate() }
        for (_, tunnel) in all {
            if tunnel.process.isRunning { tunnel.process.terminate() }
            try? FileManager.default.removeItem(at: tunnel.localSocket)
        }
    }

    public func connectionEpoch(for name: String) -> UInt64 { lock.lock(); defer { lock.unlock() }; return hostEpochs[name, default: 0] }

    /// Private loopback TCP forwards are scoped to a view generation and host.
    /// Port allocation is checked again by ssh; a collision retries with a new port.
    public func previewURL(for host: RemoteHost, surfaceID: UUID, token: UUID, specification: PreviewSpecification, expectedEpoch: UInt64? = nil) throws -> URL {
        let url = try specification.validatedURL()
        guard let remoteAddress = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host else { throw PreviewError.invalidURL }
        guard previewSlots.wait(timeout: .now()) == .success else { throw SSHTunnelError.launchFailed("Preview connection requests are busy. Reload when another request completes.") }; defer { previewSlots.signal() }
        let key = PreviewKey(host: host.name, surface: surfaceID)
        lock.lock()
        guard previewLocks[key] != nil || (previewLocks.count < 128 && previews.count < 128) else { lock.unlock(); throw SSHTunnelError.invalidConfiguration("The preview forwarding capacity is exhausted. Close previews before retrying.") }
        let gate = previewLocks[key] ?? OperationGate(); previewLocks[key] = gate; gate.users += 1
        let operationLock = gate.lock
        let epoch = expectedEpoch ?? hostEpochs[host.name, default: 0]
        lock.unlock()
        operationLock.lock()
        defer { operationLock.unlock(); lock.lock(); gate.users -= 1; if gate.users == 0 { previewLocks.removeValue(forKey: key) }; lock.unlock() }
        lock.lock(); let existing = previews[key]; let cancelled = hostEpochs[host.name, default: 0] != epoch; lock.unlock()
        guard !cancelled else { throw SSHTunnelError.notReady(host: host.name) }
        if let existing, existing.process.isRunning, existing.remoteAddress == remoteAddress, existing.remotePort == specification.effectivePort {
            lock.lock(); if previews[key]?.process === existing.process { previews[key]?.token = token }; lock.unlock()
            return try specification.forwardedURL(port: existing.port)
        }
        if let existing, existing.process.isRunning { existing.process.terminate() }
        for _ in 0..<3 {
            let port = try Self.loopbackPort()
            let process = try makePreviewProcess(host, port, remoteAddress, specification.effectivePort)
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline {
                lock.lock(); let cancelled = hostEpochs[host.name, default: 0] != epoch; lock.unlock()
                if cancelled { process.terminate(); throw SSHTunnelError.notReady(host: host.name) }
                if Self.ownsLoopbackListener(pid: process.processIdentifier, port: port) {
                    lock.lock()
                    guard hostEpochs[host.name, default: 0] == epoch else { lock.unlock(); process.terminate(); throw SSHTunnelError.notReady(host: host.name) }
                    previews[key] = PreviewForward(process: process, port: port, remoteAddress: remoteAddress, remotePort: specification.effectivePort, token: token)
                    lock.unlock()
                    return try specification.forwardedURL(port: port)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { process.terminate(); throw SSHTunnelError.notReady(host: host.name) }
        }
        throw SSHTunnelError.launchFailed("Could not bind a private preview forward or reach the SSH host. Check the host's SSH configuration and reload.")
    }
    public func stopPreview(host: String, surfaceID: UUID, token: UUID) {
        let key = PreviewKey(host: host, surface: surfaceID)
        lock.lock()
        let process = previews[key]?.token == token ? previews.removeValue(forKey: key)?.process : nil
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
    private static func defaultPreviewProcess(host: RemoteHost, localPort: Int, remoteAddress: String, remotePort: Int) throws -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var arguments = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        arguments += try validatedUserSSHArgs(host.sshArgs)
        // Preserve the requested remote loopback interface, including IPv6.
        // OpenSSH requires brackets around an IPv6 forwarding destination.
        let address = remoteAddress.contains(":") && !remoteAddress.hasPrefix("[") ? "[" + remoteAddress + "]" : remoteAddress
        arguments += ["-L", "127.0.0.1:\(localPort):\(address):\(remotePort)", try validatedSSHTarget(host.sshTarget)]
        process.arguments = arguments; process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        return process
    }
    private static func loopbackPort() throws -> Int {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw SSHTunnelError.launchFailed("Could not allocate a loopback socket.") }; defer { close(fd) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0 else { throw SSHTunnelError.launchFailed("Could not bind a loopback socket.") }
        var count = size
        let read = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &count) } }
        guard read == 0 else { throw SSHTunnelError.launchFailed("Could not read the allocated loopback port.") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    /// Read the owned process's listening descriptor, rather than assuming a port
    /// probe belongs to it. Another process can claim the allocated port first.
    static func ownsLoopbackListener(pid: Int32, port: Int) -> Bool {
        #if canImport(Darwin)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: 1024)
        let bytes = descriptors.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0, Int(bytes) < descriptors.count * MemoryLayout<proc_fdinfo>.size else { return false }
        for descriptor in descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.size) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size, info.psi.soi_family == AF_INET, info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            if tcp.tcpsi_state == TSI_S_LISTEN, Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))) == port { return true }
        }
        return false
        #else
        let directory = "/proc/\(pid)/fd"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let inodes = Set(entries.prefix(1024).compactMap { entry -> String? in
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: directory + "/" + entry), target.hasPrefix("socket:["), target.hasSuffix("]") else { return nil }
            return String(target.dropFirst(8).dropLast())
        })
        guard let table = try? String(contentsOfFile: "/proc/\(pid)/net/tcp", encoding: .utf8), table.utf8.count <= 4 << 20 else { return false }
        for line in table.split(separator: "\n").dropFirst() {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count > 9, columns[3] == "0A", inodes.contains(String(columns[9])) else { continue }
            let local = columns[1].split(separator: ":")
            if local.count == 2, local[0] == "0100007F", Int(local[1], radix: 16) == port { return true }
        }
        return false
        #endif
    }

    // MARK: - Internals

    private func spawnTunnel(host: RemoteHost, localSocket: URL, epoch: UInt64) throws {
        try? FileManager.default.createDirectory(
            at: HarnessPaths.tunnelsDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Clear any stale forwarded socket so ssh can bind it (StreamLocalBindUnlink also covers this).
        try? FileManager.default.removeItem(at: localSocket)

        let process = try makeTunnelProcess(host, localSocket)
        let diagnostics = (process.standardError as? Pipe).map(Diagnostics.init)
        process.terminationHandler = { [weak self] process in
            self?.tunnelExited(host.name, process: process)
        }

        do {
            try process.run()
        } catch {
            throw SSHTunnelError.launchFailed("\(error)")
        }
        lock.lock()
        guard hostEpochs[host.name, default: 0] == epoch else { lock.unlock(); if process.isRunning { process.terminate() }; throw SSHTunnelError.notReady(host: host.name) }
        tunnels[host.name] = Tunnel(process: process, localSocket: localSocket, diagnostics: diagnostics)
        let needsCleanupHook = !exitCleanupRegistered
        exitCleanupRegistered = true
        lock.unlock()
        // Reap the ssh child + forwarded socket on normal process exit — without this,
        // every harness-cli invocation that opened a tunnel leaves an orphaned ssh
        // process and a stale socket in runtime/tunnels/ behind.
        if needsCleanupHook {
            atexit { SSHTunnelManager.shared.stopAll() }
        }
    }

    private func tunnelExited(_ name: String, process: Process) {
        lock.lock()
        let current = tunnels[name]?.process === process
        let handler = onTunnelDropped
        lock.unlock()
        if current { handler?(name) }
    }

    static func sshArguments(for host: RemoteHost, localSocket: URL) throws -> [String] {
        var args = [
            "ssh",
            "-N",                                   // no remote command — just forward
            "-o", "ExitOnForwardFailure=yes",       // fail fast if the forward can't bind
            "-o", "StreamLocalBindUnlink=yes",      // replace a stale remote-side socket binding
            "-o", "ServerAliveInterval=15",         // keep the tunnel alive / detect drops
            "-o", "BatchMode=yes",                  // no TTY: fail with a reason instead of prompting
            "-o", "ConnectTimeout=10",
        ]
        args += try validatedUserSSHArgs(host.sshArgs)
        args += ["-L", try forwardSpec(localSocketPath: localSocket.path, remoteSocketPath: host.remoteSocketPath)]
        args += [try validatedSSHTarget(host.sshTarget)]
        return args
    }

    static func validatedUserSSHArgs(_ input: [String]) throws -> [String] {
        var output: [String] = []
        var index = 0
        while index < input.count {
            let arg = input[index]
            guard isSafeArgumentToken(arg) else {
                throw SSHTunnelError.invalidConfiguration("SSH argument contains control characters")
            }
            switch arg {
            case "-4", "-6", "-A", "-a", "-T", "-q", "-v", "-vv", "-vvv":
                output.append(arg)
                index += 1
            case "-p", "-i", "-J", "-l", "-F":
                guard index + 1 < input.count else {
                    throw SSHTunnelError.invalidConfiguration("SSH argument \(arg) requires a value")
                }
                let value = input[index + 1]
                try validateSSHValue(value, for: arg)
                output.append(contentsOf: [arg, value])
                index += 2
            default:
                if let prefix = ["-p", "-i", "-J", "-l", "-F"].first(where: { arg.hasPrefix($0) && arg.count > $0.count }) {
                    let value = String(arg.dropFirst(prefix.count))
                    try validateSSHValue(value, for: prefix)
                    output.append(arg)
                    index += 1
                } else {
                    throw SSHTunnelError.invalidConfiguration("SSH argument \(arg) is not allowed")
                }
            }
        }
        return output
    }

    private static func validateSSHValue(_ value: String, for option: String) throws {
        guard isSafeArgumentToken(value), !value.hasPrefix("-") else {
            throw SSHTunnelError.invalidConfiguration("SSH argument \(option) has an unsafe value")
        }
        if option == "-p" {
            guard let port = Int(value), (1 ... 65_535).contains(port) else {
                throw SSHTunnelError.invalidConfiguration("SSH port must be 1...65535")
            }
        }
    }

    private static func forwardSpec(localSocketPath: String, remoteSocketPath: String) throws -> String {
        guard localSocketPath.hasPrefix("/"),
              isSafeArgumentToken(localSocketPath),
              !localSocketPath.contains(":")
        else {
            throw SSHTunnelError.invalidConfiguration("local socket path must be an absolute path without ':' or control characters")
        }
        guard remoteSocketPath.hasPrefix("/"),
              isSafeArgumentToken(remoteSocketPath),
              !remoteSocketPath.contains(":")
        else {
            throw SSHTunnelError.invalidConfiguration("remote socket path must be an absolute path without ':' or control characters")
        }
        return "\(localSocketPath):\(remoteSocketPath)"
    }

    static func validatedSSHTarget(_ target: String) throws -> String {
        guard isSafeArgumentToken(target),
              !target.hasPrefix("-"),
              target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else {
            throw SSHTunnelError.invalidConfiguration("SSH target is unsafe")
        }
        return target
    }

    private static func isSafeArgumentToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    // MARK: - Production defaults for the injectable seams

    /// The shipping `ssh -N -L …` child: `/usr/bin/env ssh …` with stdout/stderr silenced.
    private static func defaultTunnelProcess(_ host: RemoteHost, _ localSocket: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = try sshArguments(for: host, localSocket: localSocket)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe() // the owned Tunnel drains a bounded memory tail
        return process
    }

    public static func logURL(for localSocket: URL) -> URL {
        localSocket.deletingPathExtension().appendingPathExtension("log")
    }

    /// Turns ssh's stderr into an actionable sentence, or nil when nothing known matched.
    public static func diagnose(_ stderr: String) -> String? {
        let text = stderr.lowercased()
        if text.contains("host key verification failed") || text.contains("no matching host key") {
            return "the host key isn't trusted yet. Run `ssh` to it once in a terminal to verify and save it."
        }
        if text.contains("remote host identification has changed") {
            return "the host key changed. Check ~/.ssh/known_hosts before trusting it."
        }
        if text.contains("permission denied") {
            return "SSH authentication failed. Harness needs key or agent auth; it can't answer a password prompt."
        }
        if text.contains("could not resolve hostname") {
            return "the host name doesn't resolve."
        }
        if text.contains("connection refused") || text.contains("connection timed out") || text.contains("operation timed out") {
            return "nothing answered on the SSH port."
        }
        if text.contains("open failed") || text.contains("no such file") || text.contains("connect failed") {
            return "the remote daemon socket isn't there. Start HarnessDaemon on the host and check the socket path."
        }
        return nil
    }

    /// The shipping reachability probe: ask the forwarded socket for a `pong`.
    private static func defaultReachabilityProbe(_ endpoint: Endpoint) -> Bool {
        guard case .pong = try? DaemonClient(endpoint: endpoint).request(.ping, timeout: 0.5) else {
            return false
        }
        return true
    }
}

/// Backoff for bringing a dropped remote tunnel back: 1, 2, 4, 8, 16, 30, 30… seconds,
/// giving up after `maxAttempts` (about three minutes in all).
public enum RemoteReconnect {
    public static let maxAttempts = 9

    public static func jitteredDelay(attempt: Int) -> TimeInterval { min(30, delay(attempt: attempt) * Double.random(in: 0.8...1.2)) }

    public static func delay(attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, attempt))))
    }
}
