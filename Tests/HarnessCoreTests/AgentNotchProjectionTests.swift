import XCTest
@testable import HarnessCore

final class AgentNotchProjectionTests: XCTestCase {
    func testSortedAgentsPrioritizesWaitingThenAttentionThenRecentActivity() {
        let old = Date(timeIntervalSince1970: 100)
        let recent = Date(timeIntervalSince1970: 200)
        let idle = agent(kind: .aider, activity: .idle, waiting: false, lastActivityAt: recent)
        let working = agent(kind: .codex, activity: .working, waiting: false, lastActivityAt: old)
        let awaiting = agent(kind: .claudeCode, activity: .awaiting, waiting: false, lastActivityAt: old)
        let waiting = agent(kind: .cursor, activity: .working, waiting: true, lastActivityAt: old, notificationText: "Approve?")

        let sorted = AgentNotchProjection.sortedAgents([idle, working, awaiting, waiting])

        XCTAssertEqual(sorted.map(\.kind), [.cursor, .claudeCode, .codex, .aider])
        XCTAssertEqual(sorted.first?.notificationText, "Approve?")
    }

    func testDashboardProjectionKeepsRowsAndCountsWork() {
        let rows = [
            AgentNotchRowSummary(
                id: "agent:api",
                rowKind: .agent,
                workspaceID: UUID(),
                workspaceName: "Default",
                sessionID: UUID(),
                sessionName: "api",
                tabID: UUID(),
                title: "api",
                detail: "Default / ~/api",
                tabCount: 1,
                waitingCount: 1,
                agentKind: .codex,
                agentActivity: .awaiting
            ),
            AgentNotchRowSummary(
                id: "session:web",
                rowKind: .session,
                workspaceID: UUID(),
                workspaceName: "Default",
                sessionID: UUID(),
                sessionName: "web",
                tabID: UUID(),
                title: "web",
                detail: "Default / ~/web",
                tabCount: 1,
                waitingCount: 0,
                agentKind: nil,
                agentActivity: nil
            ),
        ]
        let projection = AgentNotchDashboardProjection(
            agents: [agent(kind: .codex, activity: .working, waiting: false, lastActivityAt: .now)],
            rows: rows
        )

        XCTAssertEqual(projection.rows.count, 2)
        XCTAssertEqual(projection.waitingCount, 1)
        XCTAssertEqual(projection.agentCount, 1)
        XCTAssertEqual(projection.sessionCount, 2)
    }

    func testRowsExpandMultipleAgentTabsInOneSessionWithoutGenericDuplicate() {
        let sessionID = UUID()
        let cursorTab = Tab(
            title: "Cursor Agent",
            cwd: "/Users/robert/project",
            rootPane: .leaf(PaneLeaf(id: UUID(), surfaceID: UUID())),
            sortOrder: 0,
            agent: AgentSnapshot(
                kind: .cursor,
                executable: "cursor-agent",
                pid: 10,
                activity: .idle,
                lastActivityAt: Date(timeIntervalSince1970: 100)
            )
        )
        let claudeTab = Tab(
            title: "Claude Code",
            cwd: "/Users/robert/project",
            status: .waiting,
            rootPane: .leaf(PaneLeaf(id: UUID(), surfaceID: UUID())),
            sortOrder: 1,
            agent: AgentSnapshot(
                kind: .claudeCode,
                executable: "claude",
                pid: 11,
                activity: .awaiting,
                lastActivityAt: Date(timeIntervalSince1970: 200)
            )
        )
        let session = SessionGroup(
            id: sessionID,
            name: "Default",
            tabs: [cursorTab, claudeTab],
            activeTabID: cursorTab.id
        )
        let workspace = Workspace(name: "Dev", sessions: [session])
        let snapshot = SessionSnapshot(workspaces: [workspace])

        let rows = AgentNotchProjection.rows(from: snapshot)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.rowKind), [.agent, .agent])
        XCTAssertEqual(Set(rows.map(\.sessionID)), Set([sessionID]))
        XCTAssertEqual(Set(rows.compactMap(\.tabID)), Set([cursorTab.id, claudeTab.id]))
        XCTAssertEqual(Set(rows.map(\.agentKind)), Set([.cursor, .claudeCode]))
        XCTAssertEqual(rows.first?.agentKind, .claudeCode)
        XCTAssertEqual(rows.first?.waitingCount, 1)
        XCTAssertFalse(rows.contains { $0.id == "session:\(sessionID.uuidString)" })
    }

    func testRowsUseAgentListAsSourceOfTruthWhenProvided() {
        let tab = Tab(
            title: "Shell",
            cwd: "/Users/robert/project",
            rootPane: .leaf(PaneLeaf(id: UUID(), surfaceID: UUID())),
            agent: nil
        )
        let session = SessionGroup(
            name: "Default",
            tabs: [tab],
            activeTabID: tab.id
        )
        let workspace = Workspace(name: "Dev", sessions: [session])
        let snapshot = SessionSnapshot(workspaces: [workspace])
        let agent = AgentSessionSummary(
            workspaceName: workspace.name,
            sessionID: session.id,
            sessionName: session.name,
            tabID: tab.id,
            tabTitle: "Codex",
            surfaceID: tab.rootPane.allSurfaceIDs().first!.uuidString,
            paneID: nil,
            kind: .codex,
            activity: .working,
            waiting: false,
            lastActivityAt: Date(timeIntervalSince1970: 300)
        )

        let rows = AgentNotchProjection.rows(from: snapshot, agents: [agent])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].rowKind, .agent)
        XCTAssertEqual(rows[0].agentKind, .codex)
        XCTAssertEqual(rows[0].tabID, tab.id)
        XCTAssertFalse(rows.contains { $0.rowKind == .session })
    }

    func testRowsKeepGenericSessionOnlyWhenNoAgentTabs() {
        let firstTab = Tab(
            title: "Shell",
            cwd: "/Users/robert/api",
            rootPane: .leaf(PaneLeaf(id: UUID(), surfaceID: UUID())),
            sortOrder: 0
        )
        let secondTab = Tab(
            title: "Shell",
            cwd: "/Users/robert/web",
            rootPane: .leaf(PaneLeaf(id: UUID(), surfaceID: UUID())),
            sortOrder: 1
        )
        let session = SessionGroup(
            name: "Default",
            tabs: [firstTab, secondTab],
            activeTabID: firstTab.id
        )
        let snapshot = SessionSnapshot(workspaces: [Workspace(name: "Dev", sessions: [session])])

        let rows = AgentNotchProjection.rows(from: snapshot)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].rowKind, .session)
        XCTAssertEqual(rows[0].tabCount, 2)
        XCTAssertEqual(rows[0].tabID, firstTab.id)
    }

    func testAgentRowsCarryNotificationTextBranchAndPathFirstDetail() {
        let tab = Tab(
            title: "Claude Code",
            cwd: "/Users/robert/api",
            gitBranch: "feat/login",
            status: .waiting,
            rootPane: .leaf(PaneLeaf(id: UUID(), surfaceID: UUID()))
        )
        let session = SessionGroup(name: "backend", tabs: [tab], activeTabID: tab.id)
        let workspace = Workspace(name: "Dev", sessions: [session])
        let snapshot = SessionSnapshot(workspaces: [workspace])
        let agent = AgentSessionSummary(
            workspaceName: workspace.name,
            sessionID: session.id,
            sessionName: session.name,
            tabID: tab.id,
            tabTitle: tab.title,
            surfaceID: tab.rootPane.allSurfaceIDs().first!.uuidString,
            paneID: nil,
            kind: .claudeCode,
            activity: .working,
            waiting: true,
            lastActivityAt: .now,
            notificationText: "Permission needed: run tests?"
        )

        let rows = AgentNotchProjection.rows(from: snapshot, agents: [agent])

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].notificationText, "Permission needed: run tests?")
        XCTAssertEqual(rows[0].gitBranch, "feat/login")
        // Path (with branch) leads; activity is no longer part of the detail string.
        XCTAssertEqual(rows[0].detail, "api (feat/login) · Dev · backend")
        XCTAssertFalse(rows[0].detail.contains("working"))
    }

    func testSessionRowDetailLeadsWithPathAndBranch() {
        let tab = Tab(
            title: "Shell",
            cwd: "/Users/robert/web",
            gitBranch: "main",
            rootPane: .leaf(PaneLeaf(id: UUID(), surfaceID: UUID()))
        )
        let session = SessionGroup(name: "Default", tabs: [tab], activeTabID: tab.id)
        let snapshot = SessionSnapshot(workspaces: [Workspace(name: "Dev", sessions: [session])])

        let rows = AgentNotchProjection.rows(from: snapshot)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].detail, "web (main) · Dev")
        XCTAssertEqual(rows[0].gitBranch, "main")
    }

    func testHeaderSummaryPluralizesAndDropsZeroSegments() {
        XCTAssertEqual(AgentNotchProjection.headerSummary(workingCount: 0, waitingCount: 0, sessionCount: 1), "1 session")
        XCTAssertEqual(AgentNotchProjection.headerSummary(workingCount: 2, waitingCount: 1, sessionCount: 3),
                       "2 working · 1 waiting · 3 sessions")
        XCTAssertEqual(AgentNotchProjection.headerSummary(workingCount: 0, waitingCount: 1, sessionCount: 2),
                       "1 waiting · 2 sessions")
    }

    private func agent(
        kind: AgentKind,
        activity: AgentActivity,
        waiting: Bool,
        lastActivityAt: Date,
        notificationText: String? = nil
    ) -> AgentSessionSummary {
        AgentSessionSummary(
            workspaceName: "Default",
            sessionID: UUID(),
            sessionName: "session",
            tabID: UUID(),
            tabTitle: kind.displayName,
            surfaceID: UUID().uuidString,
            paneID: nil,
            kind: kind,
            activity: activity,
            waiting: waiting,
            lastActivityAt: lastActivityAt,
            notificationText: notificationText
        )
    }
}
