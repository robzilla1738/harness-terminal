import Foundation

public struct SessionSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
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
        version = SessionSnapshot.currentVersion
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        workspaces = try container.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? [Workspace()]
        activeWorkspaceID = try container.decodeIfPresent(WorkspaceID.self, forKey: .activeWorkspaceID) ?? workspaces.first?.id
        themeName = try container.decodeIfPresent(String.self, forKey: .themeName) ?? "Default"
        keepSessionsOnQuit = try container.decodeIfPresent(Bool.self, forKey: .keepSessionsOnQuit) ?? true
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? .now
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
