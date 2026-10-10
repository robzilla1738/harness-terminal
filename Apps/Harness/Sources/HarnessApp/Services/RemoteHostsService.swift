import Foundation
import HarnessCore

/// App-side facade over `RemoteHostStore` + `SSHTunnelManager`: lists/edits saved remote daemons
/// and brings up the SSH tunnels that let the GUI drive them, several at once. Connecting blocks (it spawns ssh and
/// waits for the remote daemon to answer), so callers run `connect` off the main thread.
/// @unchecked Sendable: the store/tunnel manager are thread-safe; `_activeHostName` is lock-guarded.
final class RemoteHostsService: @unchecked Sendable {
    static let shared = RemoteHostsService()

    private let store = RemoteHostStore()
    private let lock = NSLock()
    private var _activeHostName: String?

    private init() {
        SSHTunnelManager.shared.onTunnelDropped = { name in
            DispatchQueue.global(qos: .utility).async {
                _ = try? DaemonClient().request(.noteClientConnection(host: name), timeout: 1)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SessionCoordinator.shared.remoteTunnelDropped(name) }
            }
        }
    }

    /// The host the key window is on, or nil when it's on this Mac. Set by the coordinator.
    var activeHostName: String? {
        lock.lock(); defer { lock.unlock() }; return _activeHostName
    }

    func setActiveHost(_ name: String?) {
        lock.lock(); _activeHostName = name; lock.unlock()
    }

    func hosts() -> [RemoteHost] { store.load() }

    /// Saves (or replaces by name). False when the file couldn't be written.
    @discardableResult
    func addHost(_ host: RemoteHost, replacing oldName: String? = nil) -> Bool {
        let previous = store.host(named: oldName ?? host.name)
        guard store.upsert(host, replacing: oldName).saved else { return false }
        if let previous, previous != host { SSHTunnelManager.shared.stop(host: previous.name) }
        return true
    }

    /// Opens (or reuses) the tunnel for an unsaved or saved host without making it the
    /// window's host. Blocking — call off the main thread.
    func probe(_ host: RemoteHost) throws -> Endpoint {
        dropTunnelIfChanged(host)
        return try SSHTunnelManager.shared.endpoint(for: host)
    }

    /// A live forward is reused by name. When the saved destination, options, or socket
    /// differ from `host`, close it so the next connect uses the new settings.
    func dropTunnelIfChanged(_ host: RemoteHost) {
        guard let saved = store.host(named: host.name), saved != host else { return }
        SSHTunnelManager.shared.stop(host: host.name)
    }

    /// Sessions the daemon at `endpoint` reports, or 0 if it doesn't answer.
    static func sessionCount(at endpoint: Endpoint) -> Int {
        guard case let .snapshot(snapshot)? = try? DaemonClient(endpoint: endpoint).request(.getSnapshot, timeout: 3) else { return 0 }
        return snapshot.workspaces.reduce(0) { $0 + $1.sessions.count }
    }

    func removeHost(named name: String) -> Bool {
        guard store.remove(name: name).saved else { return false }
        SSHTunnelManager.shared.stop(host: name)
        lock.lock()
        if _activeHostName == name { _activeHostName = nil }
        lock.unlock()
        return true
    }

    /// Bring up (or reuse) the tunnel to `name` and return the local endpoint that reaches it.
    /// Blocking — call off the main thread.
    func connect(named name: String, expectedEpoch: UInt64? = nil) throws -> Endpoint {
        guard let host = store.host(named: name) else {
            throw DaemonSessionError.daemonError("unknown remote host '\(name)'")
        }
        return try SSHTunnelManager.shared.endpoint(for: host, expectedEpoch: expectedEpoch)
    }

    /// Tear down a host's tunnel (the coordinator has already detached from it).
    func disconnect(named name: String) {
        SSHTunnelManager.shared.stop(host: name)
    }
}
