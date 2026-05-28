import Foundation

public enum IPCRequest: Codable, Sendable {
    case ping
    case listWorkspaces
    case listSurfaces
    case newWorkspace(name: String)
    case newSession(workspaceID: UUID, cwd: String?, name: String?)
    case newTab(workspaceID: UUID, cwd: String?)
    case newTabInWorkspace(named: String, cwd: String?)
    case newSplit(tabID: UUID, paneID: UUID?, direction: SplitDirection)
    case selectWorkspace(id: UUID)
    case selectWorkspaceByName(name: String)
    case selectSession(workspaceID: UUID, sessionID: UUID)
    case selectTab(workspaceID: UUID, tabID: UUID)
    case reorderTab(workspaceID: UUID, tabID: UUID, toIndex: Int)
    case closeTab(tabID: UUID)
    case closeSession(sessionID: UUID)
    case closeWorkspace(id: UUID)
    case setTheme(name: String)
    case setKeepSessionsOnQuit(Bool)
    case notify(surfaceID: String, title: String, body: String)
    case clearNotification(surfaceID: String)
    case updateTabTitle(surfaceID: String, title: String)
    case updateTabCwd(surfaceID: String, path: String)
    case updateTabGitBranch(workspaceID: UUID, tabID: UUID, branch: String?)
    case send(surfaceID: String, text: String)
    case sendData(surfaceID: String, data: Data)
    case getSnapshot
    case createSurface(cwd: String?, shell: String?)
    case ensureSurface(surfaceID: String, cwd: String?, shell: String?, rows: UInt16, cols: UInt16, scrollbackBytes: Int?)
    case attachSurface(surfaceID: String)
    // tmux-style pane + key commands
    case sendKeys(surfaceID: String, keys: [String])
    case capturePane(surfaceID: String, includeScrollback: Bool)
    case killPane(paneID: UUID)
    case swapPanes(srcPaneID: UUID, dstPaneID: UUID)
    case resizePane(paneID: UUID, direction: ResizeDirection, amount: Int)
    /// Set an absolute split ratio. The branch is identified by the representative
    /// (first) leaf of each child subtree, which is unambiguous even when nested.
    case resizePaneRatio(tabID: UUID, firstPaneID: UUID, secondPaneID: UUID, ratio: Double)
    case zoomPane(paneID: UUID)
    case setCopyMode(surfaceID: String, enabled: Bool)
    case renameTab(tabID: UUID, name: String)
    case renameSession(sessionID: UUID, name: String)
    case renameWorkspace(workspaceID: UUID, name: String)
    case detectAgent(surfaceID: String)
    // Surface output streaming + attach
    case subscribeSurfaceOutput(surfaceID: String)
    case cancelSubscription(surfaceID: String)
    case replayScrollback(surfaceID: String, fromSequence: UInt64?)
    case resizeSurface(surfaceID: String, rows: UInt16, cols: UInt16)
    case detachSurface(surfaceID: String)
}

public enum IPCResponse: Codable, Sendable {
    case ok
    case pong
    case workspaces([WorkspaceSummary])
    case surfaces([SurfaceSummary])
    case workspaceID(UUID)
    case sessionID(UUID)
    case tabID(UUID)
    case paneID(UUID)
    case surfaceID(String)
    case snapshot(SessionSnapshot)
    case text(String)
    case data(Data, sequence: UInt64)
    case agentInfo(AgentSnapshot?)
    case error(String)
}

public enum ResizeDirection: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

public struct WorkspaceSummary: Codable, Sendable {
    public var id: UUID
    public var name: String
    public var tabCount: Int

    public init(id: UUID, name: String, tabCount: Int) {
        self.id = id
        self.name = name
        self.tabCount = tabCount
    }
}

public struct IPCEnvelope: Codable, Sendable {
    public var request: IPCRequest?

    public init(request: IPCRequest) {
        self.request = request
    }
}

public struct IPCReply: Codable, Sendable {
    public var response: IPCResponse

    public init(response: IPCResponse) {
        self.response = response
    }
}
