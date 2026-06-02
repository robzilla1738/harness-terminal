import Foundation

/// Where a `DaemonClient` connects. Today the daemon always listens on a local Unix socket; a
/// remote daemon is reached by forwarding that socket over SSH (`ssh -L`) and pointing a client at
/// the local forwarded socket — so `.unix` covers both local and (tunnelled) remote use. `.tcp` is
/// reserved for a future native encrypted transport (see the deferred TLS phase) and currently
/// throws `EndpointError.notYetSupported` when connected.
public enum Endpoint: Sendable, Equatable, Codable {
    case unix(path: String)
    case tcp(host: String, port: UInt16)

    /// The local daemon's control socket — the default target for every existing client call, so a
    /// plain `DaemonClient()` keeps talking to the local daemon exactly as before.
    public static var localControlSocket: Endpoint {
        .unix(path: HarnessPaths.socketURL.path)
    }
}

public enum EndpointError: Error, CustomStringConvertible {
    case pathTooLong(path: String, limit: Int)
    case notYetSupported(String)
    case connectionFailed

    public var description: String {
        switch self {
        case let .pathTooLong(path, limit):
            return "Socket path is \(path.utf8.count) bytes (max \(limit - 1)); shorten it. Path: \(path)"
        case let .notYetSupported(what):
            return "\(what) is not supported yet"
        case .connectionFailed:
            return "Failed to connect to the daemon endpoint"
        }
    }
}
