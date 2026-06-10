import Foundation

public struct SessionSnapshot: Codable, Sendable, Equatable {
    // v3: tabs gained `activePaneID`/`lastActivePaneID` and sessions gained
    // `lastActiveTabID`. Additive — older files decode via `decodeIfPresent` and are
    // backfilled (active pane → first leaf) on load, so no destructive migration.
    public static let currentVersion = 3

    /// The schema version written to disk. Always `currentVersion` for a freshly constructed
    /// snapshot; for a decoded snapshot, reflects the version stored in the file so that future
    /// migration logic can inspect what the file was written with (see `decodedVersion`).
    public var version: Int
    /// The version read from the file during decoding, preserved for migration decisions. Equal to
    /// `currentVersion` for in-memory snapshots that were never decoded from disk. The encoder
    /// always writes `currentVersion` (see `encode(to:)` override), so this field does NOT
    /// propagate to disk — it is purely an in-memory annotation.
    public var decodedVersion: Int
    public var revision: Int
    public var workspaces: [Workspace]
    public var activeWorkspaceID: WorkspaceID?
    public var themeName: String
    public var keepSessionsOnQuit: Bool
    public var savedAt: Date

    public init(
        version: Int = SessionSnapshot.currentVersion,
        revision: Int = 0,
        workspaces: [Workspace] = [Workspace()],
        activeWorkspaceID: WorkspaceID? = nil,
        themeName: String = "Default",
        keepSessionsOnQuit: Bool = true,
        savedAt: Date = .now
    ) {
        self.version = version
        // A programmatically constructed snapshot (not decoded from disk) is always at the
        // current schema; `decodedVersion` matches so "was this upgraded?" checks work uniformly.
        self.decodedVersion = version
        self.revision = revision
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID ?? workspaces.first?.id
        self.themeName = themeName
        self.keepSessionsOnQuit = keepSessionsOnQuit
        self.savedAt = savedAt
    }

    public var activeWorkspace: Workspace? {
        guard let activeWorkspaceID else { return workspaces.first }
        return workspaces.first { $0.id == activeWorkspaceID } ?? workspaces.first
    }

    // `decodedVersion` is intentionally excluded from CodingKeys: it is an in-memory annotation
    // only and must never appear in the persisted JSON. The encoder override below writes
    // `currentVersion` for the `version` key regardless of what `decodedVersion` holds.
    private enum CodingKeys: String, CodingKey {
        case version
        case revision
        case workspaces
        case activeWorkspaceID
        case themeName
        case keepSessionsOnQuit
        case savedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve the file's actual version in `decodedVersion` so future migration code can
        // inspect it. `version` is always stamped to `currentVersion` (the encoder writes that)
        // so callers reading the field after decoding see the current schema as expected, but the
        // original on-disk value isn't silently discarded.
        let fileVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        decodedVersion = fileVersion
        version = SessionSnapshot.currentVersion
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        // Absent OR an explicitly-empty array both repair to one workspace — a zero-workspace
        // snapshot leaves the app with no active workspace and no way to add one.
        let decodedWorkspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        workspaces = decodedWorkspaces.isEmpty ? [Workspace()] : decodedWorkspaces
        activeWorkspaceID = try container.decodeIfPresent(WorkspaceID.self, forKey: .activeWorkspaceID) ?? workspaces.first?.id
        themeName = try container.decodeIfPresent(String.self, forKey: .themeName) ?? "Default"
        keepSessionsOnQuit = try container.decodeIfPresent(Bool.self, forKey: .keepSessionsOnQuit) ?? true
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? .now
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Always write `currentVersion` — `decodedVersion` is internal only and must not
        // reach disk.  `version` (the stored property) is already `currentVersion` for all
        // normal code paths; the explicit use of the constant here makes the intent explicit.
        try container.encode(SessionSnapshot.currentVersion, forKey: .version)
        try container.encode(revision, forKey: .revision)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encodeIfPresent(activeWorkspaceID, forKey: .activeWorkspaceID)
        try container.encode(themeName, forKey: .themeName)
        try container.encode(keepSessionsOnQuit, forKey: .keepSessionsOnQuit)
        try container.encode(savedAt, forKey: .savedAt)
    }

    // `decodedVersion` is an internal annotation, not semantic data — exclude it from equality so
    // a snapshot round-tripped through disk (where `decodedVersion` is the old file version) still
    // compares equal to an equivalent in-memory snapshot. All observable fields are compared.
    public static func == (lhs: SessionSnapshot, rhs: SessionSnapshot) -> Bool {
        lhs.version == rhs.version
            && lhs.revision == rhs.revision
            && lhs.workspaces == rhs.workspaces
            && lhs.activeWorkspaceID == rhs.activeWorkspaceID
            && lhs.themeName == rhs.themeName
            && lhs.keepSessionsOnQuit == rhs.keepSessionsOnQuit
            && lhs.savedAt == rhs.savedAt
    }
}

public struct SurfaceSummary: Codable, Sendable, Equatable {
    public var surfaceID: String
    public var tabTitle: String
    public var workspaceName: String
    public var cwd: String

    public init(surfaceID: String, tabTitle: String, workspaceName: String, cwd: String) {
        self.surfaceID = surfaceID
        self.tabTitle = tabTitle
        self.workspaceName = workspaceName
        self.cwd = cwd
    }
}
