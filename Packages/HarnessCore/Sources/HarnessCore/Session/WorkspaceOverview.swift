import Foundation

/// One pane inside an overview thumbnail. The text is the live label (program
/// and directory). Drawing it never creates a terminal view and never votes a size.
public struct OverviewPane: Equatable, Sendable {
    public var program: String
    public var cwd: String
    public var liveText: String

    public init(program: String, cwd: String, liveText: String) {
        self.program = program
        self.cwd = cwd
        self.liveText = liveText
    }
}

public struct OverviewTab: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var panes: [OverviewPane]

    public init(id: String, title: String, panes: [OverviewPane]) {
        self.id = id
        self.title = title
        self.panes = panes
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
                    title: tab.title,
                    panes: panes(of: tab.rootPane, cwd: tab.cwd, command: tab.currentCommand)
                )
            }
        }
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
        case .leaf:
            let program = (command?.isEmpty == false ? command : nil) ?? "shell"
            return [OverviewPane(program: program, cwd: cwd, liveText: "\(program) — \(cwd)")]
        case let .branch(_, _, first, second):
            return panes(of: first, cwd: cwd, command: command) + panes(of: second, cwd: cwd, command: command)
        }
    }
}
