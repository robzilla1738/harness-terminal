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

    public init(
        pid: Int32,
        uptimeSeconds: Double,
        surfaceCount: Int,
        totalScrollbackBytes: Int,
        clientCount: Int,
        subscriberCount: Int,
        snapshotRevision: Int
    ) {
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.surfaceCount = surfaceCount
        self.totalScrollbackBytes = totalScrollbackBytes
        self.clientCount = clientCount
        self.subscriberCount = subscriberCount
        self.snapshotRevision = snapshotRevision
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
