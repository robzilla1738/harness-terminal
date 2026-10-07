import Foundation

/// One pane inside an overview thumbnail. The text is the live label (program
/// and directory). Drawing it never creates a terminal view and never votes a size.
public struct OverviewPane: Equatable, Sendable {
    public var program: String
    public var cwd: String
    public var liveText: String
    /// The surface to preview. Nil only for hand-built values.
    public var surfaceID: SurfaceID?

    public init(program: String, cwd: String, liveText: String, surfaceID: SurfaceID? = nil) {
        self.program = program
        self.cwd = cwd
        self.liveText = liveText
        self.surfaceID = surfaceID
    }
}

public struct OverviewTab: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var panes: [OverviewPane]
    public var sessionID: String
    public var sessionName: String
    public var agent: AgentKind?
    /// Blocked on the person (a permission or question prompt, or a waiting agent).
    public var needsYou: Bool
    /// The tab the window is showing.
    public var active: Bool

    public init(
        id: String, title: String, panes: [OverviewPane],
        sessionID: String = "", sessionName: String = "",
        agent: AgentKind? = nil, needsYou: Bool = false, active: Bool = false
    ) {
        self.id = id
        self.title = title
        self.panes = panes
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.agent = agent
        self.needsYou = needsYou
        self.active = active
    }
}

/// Keyboard workspace overview. Opening and refreshing replace the tab list.
/// Neither path changes `rows`/`cols` or increments `resizeCount`.
public struct WorkspaceOverview: Equatable, Sendable {
    public private(set) var isOpen: Bool
    public private(set) var tabs: [OverviewTab]
    public private(set) var rows: UInt16
    public private(set) var cols: UInt16
    public private(set) var resizeCount: Int

    public init(rows: UInt16, cols: UInt16) {
        isOpen = false
        tabs = []
        self.rows = rows
        self.cols = cols
        resizeCount = 0
    }

    public mutating func open(tabs: [OverviewTab]) {
        isOpen = true
        self.tabs = tabs
    }

    public mutating func refresh(tabs: [OverviewTab]) {
        self.tabs = tabs
    }

    public mutating func close() {
        isOpen = false
    }
}

public enum WorkspaceOverviewBuilder {
    /// Tabs and their split panes, including a live label per pane. Does not
    /// inspect or modify any terminal grid.
    public static func tabs(from snapshot: SessionSnapshot) -> [OverviewTab] {
        let workspace = snapshot.activeWorkspace
        let sessions = workspace?.sessions ?? []
        return sessions.flatMap { session in
            session.tabs.map { tab in
                OverviewTab(
                    id: tab.id.uuidString,
                    title: SurfaceIdentity.label(directory: tab.cwd, program: tab.currentCommand, agent: tab.agent?.kind.commandToken),
                    panes: panes(of: tab.rootPane, cwd: tab.cwd, command: tab.currentCommand),
                    sessionID: session.id.uuidString,
                    sessionName: session.name,
                    agent: tab.agent?.kind,
                    needsYou: tab.programMark?.attention == .blocked || tab.status == .waiting,
                    active: session.id == workspace?.activeSessionID && tab.id == session.activeTabID
                )
            }
        }
    }

    /// Tiles in display order: anything waiting on you first, then the rest in session
    /// order. `query` keeps tabs whose title, session name, or pane directory matches.
    public static func ordered(_ tabs: [OverviewTab], query: String = "") -> [OverviewTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty ? tabs : tabs.filter { tab in
            tab.title.localizedCaseInsensitiveContains(needle)
                || tab.sessionName.localizedCaseInsensitiveContains(needle)
                || tab.panes.contains { $0.cwd.localizedCaseInsensitiveContains(needle) || $0.program.localizedCaseInsensitiveContains(needle) }
        }
        return matching.filter(\.needsYou) + matching.filter { !$0.needsYou }
    }

    /// Grid navigation: the index `delta` cells away (±1 across, ±columns down), clamped.
    public static func move(from index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index + delta, 0), count - 1)
    }

    /// Open, or refresh while open. The active grid size is left untouched.
    public static func toggle(_ overview: inout WorkspaceOverview, snapshot: SessionSnapshot) {
        let tabs = tabs(from: snapshot)
        if overview.isOpen {
            overview.refresh(tabs: tabs)
        } else {
            overview.open(tabs: tabs)
        }
    }

    private static func panes(of node: PaneNode, cwd: String, command: String?) -> [OverviewPane] {
        switch node {
        case let .leaf(leaf):
            let ownCommand = leaf.command ?? command
            let program = (ownCommand?.isEmpty == false ? ownCommand : nil) ?? "shell"
            let directory = leaf.cwd ?? cwd
            return [OverviewPane(program: program, cwd: directory, liveText: "\(program) — \(directory)", surfaceID: leaf.surfaceID)]
        case let .branch(_, _, first, second):
            return panes(of: first, cwd: cwd, command: command) + panes(of: second, cwd: cwd, command: command)
        }
    }
}
