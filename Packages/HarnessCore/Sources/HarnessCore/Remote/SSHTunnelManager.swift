import Foundation

public enum SSHTunnelError: Error, CustomStringConvertible {
    case launchFailed(String)
    case notReady(host: String)

    public var description: String {
        switch self {
        case let .launchFailed(message): return "Failed to start SSH tunnel: \(message)"
        case let .notReady(host): return "SSH tunnel to '\(host)' did not become ready in time"
        }
    }
}

/// Manages SSH tunnels that forward a remote daemon's Unix control socket to a local socket, so the
/// existing `DaemonClient`/`DaemonSubscription` (which speak length-prefixed frames over any byte
/// stream) can drive a remote daemon unchanged. This is the "remote tmux over SSH" transport: it
/// reuses the user's existing SSH trust for both encryption and authentication, with no new crypto.
///
/// One `ssh -N -L <local>:<remote>` process per host; `endpoint(for:)` ensures it's up (re-spawning
/// if it died) and returns the local `.unix` endpoint to connect to. @unchecked Sendable: the tunnel
/// table is guarded by `lock`.
public final class SSHTunnelManager: @unchecked Sendable {
    public static let shared = SSHTunnelManager()

    private final class Tunnel {
        let process: Process
        let localSocket: URL
        init(process: Process, localSocket: URL) {
            self.process = process
            self.localSocket = localSocket
        }
    }

    private let lock = NSLock()
    private var tunnels: [String: Tunnel] = [:]

    public init() {}

    /// Ensure a tunnel to `host` is running, then return the local endpoint that reaches the remote
    /// daemon. Reuses a live tunnel; (re)spawns one if absent or dead. Blocks until the remote
    /// daemon answers a `ping` over the tunnel, or throws after `waitTimeout`.
    public func endpoint(for host: RemoteHost, waitTimeout: TimeInterval = 10) throws -> Endpoint {
        let localSocket = HarnessPaths.tunnelSocketURL(forHost: host.name)
        let endpoint = Endpoint.unix(path: localSocket.path)

        lock.lock()
        if let existing = tunnels[host.name], existing.process.isRunning {
            lock.unlock()
            if isReachable(endpoint) { return endpoint }
            // Process alive but not forwarding (e.g. remote daemon restarted): tear down + respawn.
            stop(host: host.name)
            lock.lock()
        }
        lock.unlock()

        try spawnTunnel(host: host, localSocket: localSocket)

        // Wait for the remote daemon to answer through the freshly forwarded socket.
        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if isReachable(endpoint) { return endpoint }
            // Bail early if ssh exited (bad host/auth/forward) rather than waiting the full timeout.
            lock.lock()
            let running = tunnels[host.name]?.process.isRunning ?? false
            lock.unlock()
            if !running { break }
            Thread.sleep(forTimeInterval: 0.15)
        }
        stop(host: host.name)
        throw SSHTunnelError.notReady(host: host.name)
    }

    /// Whether a host currently has a live tunnel process.
    public func isConnected(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tunnels[name]?.process.isRunning ?? false
    }

    public func stop(host name: String) {
        lock.lock()
        let tunnel = tunnels.removeValue(forKey: name)
        lock.unlock()
        guard let tunnel else { return }
        if tunnel.process.isRunning { tunnel.process.terminate() }
        try? FileManager.default.removeItem(at: tunnel.localSocket)
    }

    public func stopAll() {
        lock.lock()
        let all = tunnels
        tunnels.removeAll()
        lock.unlock()
        for (_, tunnel) in all {
            if tunnel.process.isRunning { tunnel.process.terminate() }
            try? FileManager.default.removeItem(at: tunnel.localSocket)
        }
    }

    // MARK: - Internals

    private func spawnTunnel(host: RemoteHost, localSocket: URL) throws {
        try? FileManager.default.createDirectory(
            at: HarnessPaths.tunnelsDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Clear any stale forwarded socket so ssh can bind it (StreamLocalBindUnlink also covers this).
        try? FileManager.default.removeItem(at: localSocket)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = [
            "ssh",
            "-N",                                   // no remote command — just forward
            "-o", "ExitOnForwardFailure=yes",       // fail fast if the forward can't bind
            "-o", "StreamLocalBindUnlink=yes",      // replace a stale remote-side socket binding
            "-o", "ServerAliveInterval=15",         // keep the tunnel alive / detect drops
        ]
        args += host.sshArgs
        args += ["-L", "\(localSocket.path):\(host.remoteSocketPath)", host.sshTarget]
        process.arguments = args
        // Silence ssh's own chatter; failures surface as the process exiting + the readiness timeout.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw SSHTunnelError.launchFailed("\(error)")
        }
        lock.lock()
        tunnels[host.name] = Tunnel(process: process, localSocket: localSocket)
        lock.unlock()
    }

    private func isReachable(_ endpoint: Endpoint) -> Bool {
        guard case .pong = try? DaemonClient(endpoint: endpoint).request(.ping, timeout: 0.5) else {
            return false
        }
        return true
    }
}
