import Foundation
import HarnessCore

/// App-side facade over `RemoteHostStore` + `SSHTunnelManager`: lists/edits saved remote daemons
/// and brings up the SSH tunnel that lets the GUI drive one. Connecting blocks (it spawns ssh and
/// waits for the remote daemon to answer), so callers run `connect` off the main thread.
/// @unchecked Sendable: the store/tunnel manager are thread-safe; `_activeHostName` is lock-guarded.
final class RemoteHostsService: @unchecked Sendable {
    static let shared = RemoteHostsService()

    private let store = RemoteHostStore()
    private let lock = NSLock()
    private var _activeHostName: String?

    /// The host the GUI is currently pointed at, or nil when on the local daemon.
    var activeHostName: String? {
        lock.lock(); defer { lock.unlock() }; return _activeHostName
    }

    func hosts() -> [RemoteHost] { store.load() }

    func addHost(_ host: RemoteHost) { store.upsert(host) }

    func removeHost(named name: String) {
        store.remove(name: name)
        SSHTunnelManager.shared.stop(host: name)
        lock.lock()
        if _activeHostName == name { _activeHostName = nil }
        lock.unlock()
    }

    /// Bring up (or reuse) the tunnel to `name` and return the local endpoint that reaches it.
    /// Blocking — call off the main thread.
    func connect(named name: String) throws -> Endpoint {
        guard let host = store.host(named: name) else {
            throw DaemonSessionError.daemonError("unknown remote host '\(name)'")
        }
        let endpoint = try SSHTunnelManager.shared.endpoint(for: host)
        lock.lock(); _activeHostName = name; lock.unlock()
        return endpoint
    }

    /// Tear down the active tunnel and forget it (the caller switches back to the local daemon).
    func disconnect() {
        lock.lock(); let name = _activeHostName; _activeHostName = nil; lock.unlock()
        if let name { SSHTunnelManager.shared.stop(host: name) }
    }
}
