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
    case swapTab(workspaceID: UUID, tabID: UUID, withIndex: Int)
    case renumberWindows(sessionID: UUID)
    case reorderSession(workspaceID: UUID, sessionID: UUID, toIndex: Int)
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
    /// Close a bare surface not owned by the layout (e.g. a `display-popup` shell).
    case closeSurface(surfaceID: String)
    // Pane + key commands
    case sendKeys(surfaceID: String, keys: [String])
    case capturePane(surfaceID: String, includeScrollback: Bool)
    /// `capture-pane -S <start> -E <end>`: a line range from scrollback+screen,
    /// negative numbers counting back from the bottom (tmux semantics). `escapeSequences`
    /// (`-e`) keeps SGR/escapes instead of stripping to plain text. Returns `.text`.
    case capturePaneRange(surfaceID: String, start: Int?, end: Int?, escapeSequences: Bool)
    /// `pipe-pane`: tee the pane's live output to a spawned shell command's stdin.
    /// `shellCommand == nil` stops an active pipe (toggle off).
    case pipePane(surfaceID: String, shellCommand: String?)
    /// `wait-for <channel>` (mode `wait`/`signal`/`lock`/`unlock`): named-channel
    /// synchronization. `wait`/`lock` may defer the reply (block the client) until a
    /// `signal`/`unlock`. Intercepted at the `DaemonServer` socket layer, never under the
    /// registry lock.
    case waitFor(channel: String, mode: String)
    /// `link-window`: make `tabID`'s panes appear as a new linked tab in another
    /// session (shared surfaces). `unlinkWindow` removes the linked copy.
    case linkWindow(tabID: UUID, targetSessionID: UUID)
    case unlinkWindow(tabID: UUID)
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
    case subscribeSurfaceOutput(surfaceID: String, label: String?)
    case cancelSubscription(surfaceID: String)
    case replayScrollback(surfaceID: String, fromSequence: UInt64?)
    case resizeSurface(surfaceID: String, rows: UInt16, cols: UInt16)
    case detachSurface(surfaceID: String)
    /// Identify this connection to the daemon so it shows up in `list-clients`
    /// and can be addressed by `detach-client`. Idempotent; safe to send once
    /// per persistent connection.
    case identifyClient(label: String)
    case listClients
    case detachClient(clientID: UUID)
    case daemonStats
    // Paste buffers
    case setBuffer(name: String?, data: Data)
    case getBuffer(name: String?)
    case listBuffers
    case deleteBuffer(name: String)
    case pasteBuffer(surfaceID: String, name: String?, bracketed: Bool)
    // Phase 4: layouts + pane ops
    case selectPaneDirectional(currentPaneID: UUID, direction: DirectionalAxis)
    /// Commit the active (focused) pane for a tab, server-side. Distinct from
    /// `selectPaneDirectional`, which only computes a neighbor.
    case selectPane(tabID: UUID, paneID: UUID)
    /// Long-lived subscription: the daemon pushes `snapshotChanged(revision:)` on every
    /// layout commit so clients (the attach-window compositor) re-render on structure
    /// changes without polling. Intercepted by `DaemonServer` (FD-level), like
    /// `subscribeSurfaceOutput`.
    case subscribeSnapshot(label: String?)
    case applyLayout(tabID: UUID, layout: String, mainPaneID: UUID?)
    case nextLayout(tabID: UUID)
    case previousLayout(tabID: UUID)
    case rotatePanes(tabID: UUID, forward: Bool)
    case breakPane(paneID: UUID)
    case joinPane(sourcePaneID: UUID, destPaneID: UUID, direction: SplitDirection)
    case respawnPane(surfaceID: String, keepHistory: Bool)
    // Phase 6: options + hooks + display
    case setOption(scope: String, target: String?, key: String, rawValue: String)
    case showOptions(scope: String?)
    /// Environment for spawned shells. `sessionID == nil` → global; `value == nil` → unset.
    case setEnvironment(sessionID: UUID?, key: String, value: String?)
    case showEnvironment(sessionID: UUID?)
    case bindHook(event: String, source: String, condition: String?)
    case unbindHook(id: UUID)
    case listHooks(event: String?)
    case displayMessage(format: String)
}

public enum DirectionalAxis: String, Codable, Sendable {
    case left, right, up, down

    /// Accept the short spellings (`l`, `L`, `r`, `R`, `u`, `U`, `d`, `D`)
    /// in addition to the full names. Used by CLI flag parsing.
    public init?(short: String) {
        switch short.lowercased() {
        case "l", "left": self = .left
        case "r", "right": self = .right
        case "u", "up": self = .up
        case "d", "down": self = .down
        default: return nil
        }
    }
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
    /// Pushed on a `subscribeSnapshot` channel when the layout commits at `revision`.
    case snapshotChanged(revision: Int)
    case agentInfo(AgentSnapshot?)
    case clients([ClientSummary])
    case daemonStats(DaemonStats)
    case clientID(UUID)
    case buffer(BufferSummary)
    case buffers([BufferSummary])
    case options([OptionEntry])
    case hookID(UUID)
    case hooks([HookEntry])
    case error(String)
}

public struct OptionEntry: Codable, Sendable, Equatable {
    public var scope: String
    public var target: String?
    public var key: String
    public var value: String
    public init(scope: String, target: String?, key: String, value: String) {
        self.scope = scope
        self.target = target
        self.key = key
        self.value = value
    }
}

public struct HookEntry: Codable, Sendable, Equatable {
    public var id: UUID
    public var event: String
    public var commandSource: String
    public var condition: String?
    public init(id: UUID, event: String, commandSource: String, condition: String?) {
        self.id = id
        self.event = event
        self.commandSource = commandSource
        self.condition = condition
    }
}

public struct BufferSummary: Codable, Sendable, Equatable {
    public var name: String
    public var byteCount: Int
    public var preview: String
    public var createdAt: Date
    public var data: Data?

    public init(name: String, byteCount: Int, preview: String, createdAt: Date, data: Data? = nil) {
        self.name = name
        self.byteCount = byteCount
        self.preview = preview
        self.createdAt = createdAt
        self.data = data
    }
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
