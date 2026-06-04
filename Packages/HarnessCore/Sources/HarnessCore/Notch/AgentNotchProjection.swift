import Foundation

public struct AgentNotchRowSummary: Sendable, Equatable, Identifiable {
    public enum RowKind: String, Sendable, Equatable {
        case agent
        case session
    }

    public var id: String
    public var rowKind: RowKind
    public var workspaceID: UUID
    public var workspaceName: String
    public var sessionID: UUID
    public var sessionName: String
    public var tabID: UUID?
    public var title: String
    public var detail: String
    public var tabCount: Int
    public var waitingCount: Int
    public var agentKind: AgentKind?
    public var agentActivity: AgentActivity?
    public var lastActivityAt: Date?
    /// The most recent hook-notification body when the agent is waiting — the densest
    /// "why is it blocked" signal, rendered as the row subtitle while waiting.
    public var notificationText: String?
    /// The tab's git branch, shown next to the cwd in the subtitle.
    public var gitBranch: String?

    public init(
        id: String,
        rowKind: RowKind,
        workspaceID: UUID,
        workspaceName: String,
        sessionID: UUID,
        sessionName: String,
        tabID: UUID?,
        title: String,
        detail: String,
        tabCount: Int,
        waitingCount: Int,
        agentKind: AgentKind?,
        agentActivity: AgentActivity?,
        lastActivityAt: Date? = nil,
        notificationText: String? = nil,
        gitBranch: String? = nil
    ) {
        self.id = id
        self.rowKind = rowKind
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.tabID = tabID
        self.title = title
        self.detail = detail
        self.tabCount = tabCount
        self.waitingCount = waitingCount
        self.agentKind = agentKind
        self.agentActivity = agentActivity
        self.lastActivityAt = lastActivityAt
        self.notificationText = notificationText
        self.gitBranch = gitBranch
    }
}

public struct AgentNotchDashboardProjection: Sendable, Equatable {
    public var agents: [AgentSessionSummary]
    public var rows: [AgentNotchRowSummary]

    public var waitingCount: Int {
        rows.reduce(0) { $0 + $1.waitingCount }
    }

    public var workingCount: Int {
        rows.filter { $0.agentActivity == .working }.count
    }

    public var agentCount: Int {
        rows.filter { $0.agentKind != nil }.count
    }

    public var sessionCount: Int {
        Set(rows.map(\.sessionID)).count
    }

    public init(
        agents: [AgentSessionSummary],
        rows: [AgentNotchRowSummary]
    ) {
        self.agents = AgentNotchProjection.sortedAgents(agents)
        self.rows = AgentNotchProjection.sortedRows(rows)
    }
}

public enum AgentNotchProjection {
    private struct TabContext {
        var workspace: Workspace
        var session: SessionGroup
        var tab: Tab
    }

    /// Build the notch overview rows from daemon snapshot truth.
    ///
    /// Contract: emit one row for every AI-bearing tab, and emit a generic session row only
    /// for sessions that have no AI-bearing tabs. This prevents the HUD from showing an
    /// agent row plus a duplicate session row for the same tab, while still showing every
    /// AI tool when multiple agent tabs live inside one Harness session.
    public static func rows(from snapshot: SessionSnapshot) -> [AgentNotchRowSummary] {
        rows(from: snapshot, agents: SessionEditor(snapshot: snapshot).listAgents())
    }

    public static func rows(
        from snapshot: SessionSnapshot,
        agents: [AgentSessionSummary]
    ) -> [AgentNotchRowSummary] {
        let contexts = tabContexts(from: snapshot)
        let agentTabIDs = Set(agents.map(\.tabID))
        var rows: [AgentNotchRowSummary] = []

        for agent in agents {
            guard let context = contexts[agent.tabID] else { continue }
            rows.append(AgentNotchRowSummary(
                id: "agent:\(agent.tabID.uuidString)",
                rowKind: .agent,
                workspaceID: context.workspace.id,
                workspaceName: context.workspace.name,
                sessionID: context.session.id,
                sessionName: context.session.name,
                tabID: agent.tabID,
                title: agent.kind.displayName,
                detail: agentDetail(
                    workspace: context.workspace,
                    session: context.session,
                    tab: context.tab,
                    agent: agent
                ),
                tabCount: 1,
                waitingCount: agent.waiting ? 1 : 0,
                agentKind: agent.kind,
                agentActivity: agent.activity,
                lastActivityAt: agent.lastActivityAt,
                notificationText: agent.notificationText,
                gitBranch: context.tab.gitBranch
            ))
        }

        for workspace in snapshot.workspaces {
            for session in sessionOrder(workspace.sessions) {
                let hasAgentRows = session.tabs.contains { agentTabIDs.contains($0.id) }
                if !hasAgentRows {
                    let activeTab = session.activeTab ?? session.tabs.first
                    rows.append(AgentNotchRowSummary(
                        id: "session:\(session.id.uuidString)",
                        rowKind: .session,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        sessionID: session.id,
                        sessionName: session.name,
                        tabID: activeTab?.id,
                        title: session.name.isEmpty ? displayTitle(for: activeTab) : session.name,
                        detail: sessionDetail(workspace: workspace, session: session, tab: activeTab),
                        tabCount: session.tabs.count,
                        waitingCount: session.tabs.filter { $0.status == .waiting }.count,
                        agentKind: nil,
                        agentActivity: nil,
                        gitBranch: activeTab?.gitBranch
                    ))
                }
            }
        }

        return sortedRows(rows)
    }

    /// Header summary line: only nonzero segments, correctly pluralized —
    /// "2 working · 1 waiting · 3 sessions"; quiet fallback "1 session" when nothing is active.
    /// (The old header printed "0 agents / 1 sessions".)
    public static func headerSummary(workingCount: Int, waitingCount: Int, sessionCount: Int) -> String {
        var parts: [String] = []
        if workingCount > 0 { parts.append("\(workingCount) working") }
        if waitingCount > 0 { parts.append("\(waitingCount) waiting") }
        parts.append(sessionCount == 1 ? "1 session" : "\(sessionCount) sessions")
        return parts.joined(separator: " · ")
    }

    public static func sortedAgents(_ agents: [AgentSessionSummary]) -> [AgentSessionSummary] {
        agents.sorted { lhs, rhs in
            let lhsRank = rank(agent: lhs)
            let rhsRank = rank(agent: rhs)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
    }

    private static func tabContexts(from snapshot: SessionSnapshot) -> [UUID: TabContext] {
        var contexts: [UUID: TabContext] = [:]
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    contexts[tab.id] = TabContext(workspace: workspace, session: session, tab: tab)
                }
            }
        }
        return contexts
    }

    public static func sortedRows(_ rows: [AgentNotchRowSummary]) -> [AgentNotchRowSummary] {
        rows.enumerated().sorted { lhs, rhs in
            let lhsRank = rank(row: lhs.element)
            let rhsRank = rank(row: rhs.element)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if let lhsDate = lhs.element.lastActivityAt, let rhsDate = rhs.element.lastActivityAt,
               lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func rank(agent: AgentSessionSummary) -> Int {
        if agent.waiting { return 4 }
        switch agent.activity {
        case .awaiting: return 3
        case .errored: return 2
        case .working: return 1
        case .idle: return 0
        }
    }

    private static func rank(row: AgentNotchRowSummary) -> Int {
        if row.waitingCount > 0 { return 4 }
        switch row.agentActivity {
        case .awaiting: return 3
        case .errored: return 2
        case .working: return 1
        case .idle, .none: return 0
        }
    }

    private static func sessionOrder(_ sessions: [SessionGroup]) -> [SessionGroup] {
        sessions.enumerated().sorted { lhs, rhs in
            if lhs.element.sortOrder != rhs.element.sortOrder {
                return lhs.element.sortOrder < rhs.element.sortOrder
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Row subtitle: most-specific first — `cwd (branch) · tab-title · workspace · session`.
    /// Activity is *not* part of the detail (the dot + badge carry state); the old
    /// "working / Default / robert" wasted the densest slot on a word the UI already shows.
    private static func agentDetail(
        workspace: Workspace,
        session: SessionGroup,
        tab: Tab,
        agent: AgentSessionSummary
    ) -> String {
        var parts: [String] = []
        let path = pathDisplayName(tab.cwd)
        if !path.isEmpty {
            parts.append(tab.gitBranch.map { "\(path) (\($0))" } ?? path)
        }
        let title = displayTitle(for: tab)
        if !title.isEmpty, title != agent.kind.displayName, title != path {
            parts.append(title)
        }
        parts.append(workspace.name)
        if !session.name.isEmpty, session.name != path { parts.append(session.name) }
        return parts.joined(separator: " · ")
    }

    private static func sessionDetail(workspace: Workspace, session: SessionGroup, tab: Tab?) -> String {
        var parts: [String] = []
        if let tab {
            let path = pathDisplayName(tab.cwd)
            if !path.isEmpty {
                parts.append(tab.gitBranch.map { "\(path) (\($0))" } ?? path)
            }
        }
        if session.tabs.count != 1 { parts.append("\(session.tabs.count) tabs") }
        parts.append(workspace.name)
        return parts.joined(separator: " · ")
    }

    private static func displayTitle(for tab: Tab?) -> String {
        guard let tab else { return "Session" }
        let fromPath = pathDisplayName(tab.cwd)
        if !tab.title.isEmpty, tab.title != "Shell" { return tab.title }
        if !fromPath.isEmpty { return fromPath }
        return "Terminal"
    }

    private static func pathDisplayName(_ path: String) -> String {
        if path == "/" { return "/" }
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }
}
