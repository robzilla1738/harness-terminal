import XCTest
@testable import HarnessCore

final class AgentSessionSummaryTests: XCTestCase {
    // MARK: - State model encoding/decoding

    func testRoundTripsThroughCodable() throws {
        for activity in [AgentActivity.idle, .working, .awaiting, .errored] {
            for waiting in [false, true] {
                let summary = AgentSessionSummary(
                    workspaceName: "Default",
                    sessionID: UUID(),
                    sessionName: "alpha",
                    tabID: UUID(),
                    tabTitle: "claude",
                    surfaceID: UUID().uuidString,
                    paneID: UUID().uuidString,
                    kind: .claudeCode,
                    activity: activity,
                    waiting: waiting,
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
                    notificationText: waiting ? "Approve?" : nil
                )
                let data = try JSONEncoder().encode(summary)
                let decoded = try JSONDecoder().decode(AgentSessionSummary.self, from: data)
                XCTAssertEqual(decoded, summary)
            }
        }
    }

    func testEncodesNilOptionalsAndDerivedName() throws {
        let summary = AgentSessionSummary(
            workspaceName: "ws",
            sessionID: UUID(),
            sessionName: "",
            tabID: UUID(),
            tabTitle: "shell",
            surfaceID: UUID().uuidString,
            paneID: nil,
            kind: .codex,
            activity: .working,
            waiting: false,
            lastActivityAt: .now,
            notificationText: nil
        )
        // agentName is derived from kind.displayName.
        XCTAssertEqual(summary.agentName, "Codex")
        // id is the backing surface id.
        XCTAssertEqual(summary.id, summary.surfaceID)
        let decoded = try JSONDecoder().decode(
            AgentSessionSummary.self,
            from: try JSONEncoder().encode(summary)
        )
        XCTAssertNil(decoded.paneID)
        XCTAssertNil(decoded.notificationText)
        XCTAssertEqual(decoded.agentName, "Codex")
    }

    // MARK: - SessionEditor.listAgents() derivation

    /// One workspace, two sessions: `alpha` has a tab with a detected agent that is
    /// `.waiting`; `beta` has a tab with no agent. Only the agent-bearing tab appears.
    func testListAgentsEmitsOnlyAgentBearingTabsWithContext() {
        var editor = SessionEditor()
        let ws = editor.snapshot.activeWorkspace!.id
        let alpha = editor.snapshot.activeWorkspace!.sessions[0].id
        _ = editor.renameSession(alpha, name: "alpha")

        // The agent-bearing tab is alpha's seeded tab.
        let alphaTab = editor.snapshot.activeWorkspace!.sessions.first { $0.id == alpha }!.tabs[0]
        let surface = alphaTab.rootPane.allSurfaceIDs().first!
        let activePane = alphaTab.activePaneID!
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        editor.setAgent(
            AgentSnapshot(kind: .claudeCode, executable: "/bin/claude", pid: 4321, activity: .awaiting, lastActivityAt: when),
            forSurfaceKey: surface.uuidString
        )
        editor.setTabStatus(workspaceID: ws, tabID: alphaTab.id, status: .waiting, notificationText: "Approve?")

        // A second session with a tab and NO agent.
        _ = editor.addSession(to: ws, name: "beta")

        let agents = editor.listAgents()
        XCTAssertEqual(agents.count, 1, "only the tab carrying an agent should appear")

        let row = agents[0]
        XCTAssertEqual(row.sessionName, "alpha")
        XCTAssertEqual(row.tabID, alphaTab.id)
        XCTAssertEqual(row.kind, .claudeCode)
        XCTAssertEqual(row.activity, .awaiting)
        XCTAssertTrue(row.waiting, "tab.status == .waiting must surface as waiting")
        XCTAssertEqual(row.notificationText, "Approve?")
        XCTAssertEqual(row.lastActivityAt, when)
        // Surface/pane resolve to the tab's active pane.
        XCTAssertEqual(row.surfaceID, surface.uuidString)
        XCTAssertEqual(row.paneID, activePane.uuidString)
    }

    func testListAgentsReportsActivePaneSurfaceAfterSplit() {
        var editor = SessionEditor()
        let ws = editor.snapshot.activeWorkspace!.id
        let tab = editor.snapshot.activeWorkspace!.sessions[0].tabs[0]
        let firstPane = tab.rootPane.allPaneIDs().first!
        _ = editor.splitPane(in: ws, tabID: tab.id, paneID: firstPane, direction: .vertical)

        // Re-read the tab; set an agent on the whole tab (per-tab agent state).
        let splitTab = editor.snapshot.activeWorkspace!.sessions[0].tabs[0]
        let anySurface = splitTab.rootPane.allSurfaceIDs().first!
        editor.setAgent(
            AgentSnapshot(kind: .codex, executable: "/bin/codex", pid: 7, activity: .working),
            forSurfaceKey: anySurface.uuidString
        )

        let agents = editor.listAgents()
        XCTAssertEqual(agents.count, 1)
        // The reported pane/surface is the active one, which must be a real leaf in the tab.
        let activeTab = editor.snapshot.activeWorkspace!.sessions[0].tabs[0]
        XCTAssertEqual(agents[0].paneID, activeTab.activePaneID?.uuidString)
        XCTAssertTrue(activeTab.rootPane.allSurfaceIDs().map(\.uuidString).contains(agents[0].surfaceID))
        XCTAssertFalse(agents[0].waiting)
    }
}
