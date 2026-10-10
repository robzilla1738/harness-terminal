import Foundation

/// Snapshot of daemon health used by `harness-cli daemon-stats` and support tooling.
public struct DaemonStats: Codable, Sendable {
    public var epoch: String?
    public var pid: Int32
    public var uptimeSeconds: Double
    public var surfaceCount: Int
    /// Active pipe consumers plus bounded accepted-output drains owned by the host.
    public var pipeConsumerCount: Int?
    public var pendingProcessRetirements: Int?
    public var shutdownPending: Bool?
    public var pendingDaemonRetirements: Int?
    public var totalScrollbackBytes: Int
    public var clientCount: Int
    public var subscriberCount: Int
    public var snapshotRevision: Int
    /// Marketing version (`HarnessVersion.short`) of the running daemon. Optional because
    /// daemons predating the version handshake never send it; IPC payloads are JSON, so the
    /// missing key decodes as nil and an old client just ignores the new key.
    public var version: String?
    /// Build number of the running daemon for component display and pending-update
    /// information. Protocol and capability compatibility govern usable operations;
    /// a build difference cannot authorize stopping programs.
    public var build: Int?
    /// Protocol features beyond the baseline (`attach-stream`). Nil from older daemons.
    public var capabilities: [String]?
    public var protocolLevel: Int?
    public var daemonPID: Int32?
    public var sessionHostPID: Int32?
    public var sessionHostBuild: Int?
    public var sessionHostProtocolLevel: Int?
    public var sessionHostCapabilities: [String]?
    public var sessionHostVersion: String?
    public var daemonAvailable: Bool?
    public var historyProtection: HistoryProtection.Kind?
    public var historyUnavailable: String?
    /// Idle surfaces whose ring is held compressed, and that ring's size stored vs raw.
    public var parkedSurfaceCount: Int?
    public var parkedStoredBytes: Int?
    public var parkedRawBytes: Int?
    /// Milliseconds spent in each startup phase (`layout`, `surfaces`, `listen`).
    public var startupMillis: [String: Double]?

    public init(
        pid: Int32,
        uptimeSeconds: Double,
        surfaceCount: Int,
        totalScrollbackBytes: Int,
        clientCount: Int,
        subscriberCount: Int,
        snapshotRevision: Int,
        version: String? = nil,
        build: Int? = nil,
        capabilities: [String]? = nil,
        parkedSurfaceCount: Int? = nil,
        parkedStoredBytes: Int? = nil,
        parkedRawBytes: Int? = nil,
        startupMillis: [String: Double]? = nil,
        epoch: String? = nil,
        protocolLevel: Int? = nil,
        sessionHostPID: Int32? = nil,
        sessionHostBuild: Int? = nil
    ) {
        self.epoch = epoch
        self.protocolLevel = protocolLevel
        self.sessionHostPID = sessionHostPID
        self.sessionHostBuild = sessionHostBuild
        self.pid = pid
        self.uptimeSeconds = uptimeSeconds
        self.surfaceCount = surfaceCount
        self.totalScrollbackBytes = totalScrollbackBytes
        self.clientCount = clientCount
        self.subscriberCount = subscriberCount
        self.snapshotRevision = snapshotRevision
        self.version = version
        self.build = build
        self.capabilities = capabilities
        self.parkedSurfaceCount = parkedSurfaceCount
        self.parkedStoredBytes = parkedStoredBytes
        self.parkedRawBytes = parkedRawBytes
        self.startupMillis = startupMillis
    }
}

public extension DaemonStats {
    static let sessionHost = "session-host-handover"
    static let currentSessionHostProtocolLevel = 8
    static let sessionHostWorker = "session-host-worker-v\(currentSessionHostProtocolLevel)"
    static let workloadInput = "workload-stdin-v1"
    static let clientCapabilities = "client-capabilities-v1"
    static let notificationPolicy = "notification-policy-v1"
    static let powerManagement = "power-management-v1"
    static let commandOutput = "command-output-v1"
    static let automaticResume = "pane-auto-resume-v1"
    static let paneResume = "pane-resume-v1"
    static let paneResources = "pane-resources-v1"
    static let activityProfiles = "activity-profiles-v1"
    static let historyRecovery = "history-recovery-v1"
    static let usageDigest = "usage-digest-v1"
    static let repositoryDigest = "repository-digest-v1"
    static let agentIdentities = "agent-identities-v1"
    static let activityState = "activity-state-v2"
    static let terminalGeometry = "terminal-geometry-events-v1"
    static let paneContent = "pane-content-v1"
    static let activityHistory = "activity-history-v1"
    static let guardedRestart = "guarded-restart"
    static var currentCapabilities: [String] {
        [agentIdentities, mobileCompanion, attachStream, paneAttention, sessionLibrary, outputSearch, filteredOutputSearch, managedWorktrees, fanout, schedules, hookPolicy, aiSummaries, pathSearch, guardedRestart, activityHistory, activityState, paneContent, terminalGeometry, usageDigest, repositoryDigest, paneResources, historyRecovery, activityProfiles, paneResume, automaticResume, commandOutput, powerManagement, notificationPolicy, clientCapabilities]
    }
    var mayRestartWithoutInterruption: Bool { surfaceCount == 0 && (pipeConsumerCount ?? 0) == 0 && (pendingProcessRetirements ?? 0) == 0 && (pendingDaemonRetirements ?? 0) == 0 }
    var updateAvailable: Bool {
        daemonUpdateAvailable || sessionHostUpdateAvailable
    }
    var daemonUpdateAvailable: Bool { build != HarnessVersion.build || !Set(Self.currentCapabilities).isSubset(of: Set(capabilities ?? [])) }
    var sessionHostUpdateAvailable: Bool {
        guard sessionHostPID != nil else { return false }
        return sessionHostBuild != HarnessVersion.build || sessionHostProtocolLevel != Self.currentSessionHostProtocolLevel
    }
    var compatibility: DaemonCompatibility {
        if let protocolLevel {
            return protocolLevel == HarnessVersion.protocolLevel ? .compatible : .incompatible
        }
        // The verified 2.1.0 wire contract. Do not infer future compatibility from build numbers.
        if build == 132, capabilities?.contains(Self.attachStream) == true { return .compatible }
        return .unknown
    }
    func supports(_ capability: String) -> Bool { capabilities?.contains(capability) == true }
    static let mobileCompanion = "mobile-companion-v1"
    static let attachStream = "attach-stream"
    static let paneAttention = "pane-attention"
    static let sessionLibrary = "session-library"
    static let hookPolicy = "hook-policy-v1"
    static let aiSummaries = "ai-summaries-v1"
    static let schedules = "schedules-v1"
    static let fanout = "fanout-v1"
    static let managedWorktrees = "managed-worktrees-v1"
    static let filteredOutputSearch = "filtered-output-search-v1"
    static let outputSearch = "output-search"
    static let pathSearch = "path-search"

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
    public var kind: String
    public var version: String
    public var principalUID: UInt32?
    public var tunnel: Bool
    public var age: TimeInterval

    public init(
        id: UUID,
        label: String,
        attachedSurfaceIDs: [String],
        connectedAt: Date,
        kind: String = "client",
        version: String = "",
        principalUID: UInt32? = nil,
        tunnel: Bool = false,
        age: TimeInterval = 0
    ) {
        self.id = id
        self.label = label
        self.attachedSurfaceIDs = attachedSurfaceIDs
        self.connectedAt = connectedAt
        self.kind = kind
        self.version = version
        self.principalUID = principalUID
        self.tunnel = tunnel
        self.age = age
    }
}
