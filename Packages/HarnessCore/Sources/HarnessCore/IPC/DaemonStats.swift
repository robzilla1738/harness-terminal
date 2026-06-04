import Foundation

/// Snapshot of daemon health used by `harness-cli daemon-stats` and support tooling.
public struct DaemonStats: Codable, Sendable {
    public var pid: Int32
    public var uptimeSeconds: Double
    public var surfaceCount: Int
    public var totalScrollbackBytes: Int
    public var clientCount: Int
    public var subscriberCount: Int
    public var snapshotRevision: Int
    /// Marketing version (`HarnessVersion.short`) of the running daemon. Optional because
    /// daemons predating the version handshake never send it; IPC payloads are JSON, so the
    /// missing key decodes as nil and an old client just ignores the new key.
    public var version: String?
    /// Build number (`HarnessVersion.build`) of the running daemon — the handshake the app
    /// and CLI compare against their own build to detect a stale daemon (issue #60).
    public var build: Int?

    public init(
        pid: Int32,
        uptimeSeconds: Double,
        surfaceCount: Int,
        totalScrollbackBytes: Int,
        clientCount: Int,
        subscriberCount: Int,
        snapshotRevision: Int,
        version: String? = nil,
        build: Int? = nil
    ) {
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.surfaceCount = surfaceCount
        self.totalScrollbackBytes = totalScrollbackBytes
        self.clientCount = clientCount
        self.subscriberCount = subscriberCount
        self.snapshotRevision = snapshotRevision
        self.version = version
        self.build = build
    }
}

public extension DaemonStats {
    /// Whether the daemon these stats describe is stale relative to `expectedBuild`
    /// (the caller's `HarnessVersion.build`). A nil build is a daemon too old to know
    /// the handshake — stale by definition. `!=` rather than `<` so a rollback (daemon
    /// newer than the app) also heals back to the app's build.
    func isStale(comparedTo expectedBuild: Int) -> Bool {
        guard let build else { return true }
        return build != expectedBuild
    }
}

/// Summary of a connected client (a Harness.app instance or an attached
/// `harness-cli` process). Used by `list-clients` / `detach-client`.
public struct ClientSummary: Codable, Sendable {
    public var id: UUID
    public var label: String
    public var attachedSurfaceIDs: [String]
    public var connectedAt: Date

    public init(id: UUID, label: String, attachedSurfaceIDs: [String], connectedAt: Date) {
        self.id = id
        self.label = label
        self.attachedSurfaceIDs = attachedSurfaceIDs
        self.connectedAt = connectedAt
    }
}
