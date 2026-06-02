import Foundation

public enum DaemonSessionError: Error, CustomStringConvertible {
    case daemonError(String)
    case unexpectedResponse

    public var description: String {
        switch self {
        case let .daemonError(msg): msg
        case .unexpectedResponse: "Unexpected response from HarnessDaemon"
        }
    }
}

/// Client wrapper used by Harness.app for all session mutations. Can be repointed at a different
/// daemon at runtime — e.g. a remote one over an SSH tunnel — via `switchEndpoint`.
/// @unchecked Sendable: the client + endpoint are guarded by `lock`; `DaemonClient` is thread-safe.
public final class DaemonSessionService: @unchecked Sendable {
    private let lock = NSLock()
    private var client: DaemonClient
    private var _endpoint: Endpoint

    public init(endpoint: Endpoint = .localControlSocket) {
        _endpoint = endpoint
        client = DaemonClient(endpoint: endpoint)
    }

    /// The daemon this service currently targets.
    public var endpoint: Endpoint {
        lock.lock(); defer { lock.unlock() }; return _endpoint
    }

    /// Repoint at a different daemon. Subsequent requests use the new endpoint; each request opens
    /// its own connection, so in-flight ones on the old client are unaffected.
    public func switchEndpoint(_ endpoint: Endpoint) {
        lock.lock()
        _endpoint = endpoint
        client = DaemonClient(endpoint: endpoint)
        lock.unlock()
    }

    private func currentClient() -> DaemonClient {
        lock.lock(); defer { lock.unlock() }; return client
    }

    @discardableResult
    public func request(_ ipcRequest: IPCRequest) throws -> IPCResponse {
        try request(ipcRequest, timeout: 2)
    }

    /// Timeout-tunable variant. Quit-time reaping (`closeEphemeralSessions`) wants a longer window
    /// than the snappy default so a momentarily busy daemon still confirms before the process exits.
    @discardableResult
    public func request(_ ipcRequest: IPCRequest, timeout: TimeInterval) throws -> IPCResponse {
        let response = try currentClient().request(ipcRequest, timeout: timeout)
        if case let .error(message) = response {
            throw DaemonSessionError.daemonError(message)
        }
        return response
    }

    public func fetchSnapshot() throws -> SessionSnapshot {
        let response = try request(.getSnapshot)
        guard case let .snapshot(snapshot) = response else {
            throw DaemonSessionError.unexpectedResponse
        }
        return snapshot
    }

    public func ping() -> Bool {
        guard let response = try? request(.ping) else { return false }
        if case .pong = response { return true }
        return false
    }
}
