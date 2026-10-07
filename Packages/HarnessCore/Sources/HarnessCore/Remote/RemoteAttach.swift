import Foundation

/// Remote attach reuses the SSH-forwarded framed socket. There is no second framing type.
public enum RemoteAttach {
    /// Shown wherever a remote session is offered. The session is the user's daemon over the user's SSH.
    public static let explanation = "This remote session is your daemon on that machine, over your SSH."

    /// A tunneled endpoint is the local forward under the tunnels directory.
    /// The local control socket and an in-pane `HARNESS_SERVER` path are not tunnels.
    public static func isTunnel(_ endpoint: Endpoint) -> Bool {
        guard case let .unix(path) = endpoint else { return false }
        let root = HarnessPaths.tunnelsDirectory.path
        return path == root || path.hasPrefix(root + "/")
    }
}
