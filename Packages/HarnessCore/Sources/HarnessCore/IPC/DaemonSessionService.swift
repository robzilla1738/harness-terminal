import Foundation
#if canImport(os)
import os
#endif

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
        let start = DispatchTime.now().uptimeNanoseconds
        defer { Self.latency.record(start: start, request: ipcRequest) }
        let response = try currentClient().request(ipcRequest, timeout: timeout)
        if case let .error(message) = response {
            throw DaemonSessionError.daemonError(message)
        }
        return response
    }

    /// Minimal, throttled latency instrumentation for the (synchronous, main-thread-callable) IPC
    /// request path. The 2s sync round trip is otherwise invisible: a momentarily slow daemon stalls
    /// the UI with no signal. This logs a `slow IPC` line (subsystem `com.robert.harness`, category
    /// `ipc`) when a request exceeds `slowThresholdNanos` (~250ms), at most once per `throttle`
    /// window so a struggling daemon can't flood the log. Read with
    /// `log stream --predicate 'subsystem == "com.robert.harness" && category == "ipc"'`. No behavior
    /// change — purely observational; the request itself is untouched (no async conversion).
    private static let latency = LatencyMonitor()

    private final class LatencyMonitor: @unchecked Sendable {
        static let slowThresholdNanos: UInt64 = 250_000_000 // 250 ms
        static let throttleNanos: UInt64 = 1_000_000_000    // ≤1 slow log/second
        private let lock = NSLock()
        private var lastLogUptime: UInt64 = 0
        #if canImport(os)
        private let logger = Logger(subsystem: "com.robert.harness", category: "ipc")
        private let signposter = OSSignposter(subsystem: "com.robert.harness", category: "ipc")
        #endif

        func record(start: UInt64, request: IPCRequest) {
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            guard elapsed >= Self.slowThresholdNanos else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock()
            guard now &- lastLogUptime >= Self.throttleNanos else { lock.unlock(); return }
            lastLogUptime = now
            lock.unlock()
            #if canImport(os)
            let millis = elapsed / 1_000_000
            logger.log("slow IPC: \(Self.label(request), privacy: .public) took \(millis)ms")
            signposter.emitEvent("slow-ipc")
            #endif
        }

        /// A coarse, non-sensitive request label (the case name only — never argument values, which
        /// can carry cwd/text/clipboard payloads). Enough to attribute a stall to a request kind.
        private static func label(_ request: IPCRequest) -> String {
            String(describing: request).split(separator: "(", maxSplits: 1).first.map(String.init)
                ?? String(describing: request)
        }
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
