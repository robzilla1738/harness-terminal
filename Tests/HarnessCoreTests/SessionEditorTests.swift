import XCTest
@testable import HarnessCore

final class SessionEditorTests: XCTestCase {
    func testAddTabStaysInsideActiveSession() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let firstSessionID = try XCTUnwrap(workspace.activeSessionID)

        let secondSessionID = try XCTUnwrap(editor.addSession(to: workspace.id, cwd: "/tmp/api", name: "api"))
        XCTAssertNotEqual(firstSessionID, secondSessionID)
        XCTAssertEqual(editor.snapshot.activeWorkspace?.sessions.count, 2)

        let newTabID = try XCTUnwrap(editor.addTab(to: workspace.id, cwd: "/tmp/api/routes"))
        let updated = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let firstSession = try XCTUnwrap(updated.sessions.first { $0.id == firstSessionID })
        let secondSession = try XCTUnwrap(updated.sessions.first { $0.id == secondSessionID })

        XCTAssertEqual(firstSession.tabs.count, 1)
        XCTAssertEqual(secondSession.tabs.count, 2)
        XCTAssertEqual(secondSession.activeTabID, newTabID)
        XCTAssertEqual(updated.activeSessionID, secondSessionID)
    }

    func testNewTabFallsBackToExistingParentDirectory() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tabID = try XCTUnwrap(editor.addTab(to: workspace.id, cwd: "/tmp/harness-missing-child/inner"))
        let tab = try XCTUnwrap(editor.snapshot.activeWorkspace?.tabs.first { $0.id == tabID })
        XCTAssertEqual(tab.cwd, "/tmp")
    }

    func testClosingLastSessionLeavesReplacementSession() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let sessionID = try XCTUnwrap(workspace.activeSessionID)

        XCTAssertTrue(editor.closeSession(sessionID))

        let updated = try XCTUnwrap(editor.snapshot.activeWorkspace)
        XCTAssertEqual(updated.sessions.count, 1)
        XCTAssertNotEqual(updated.activeSessionID, sessionID)
        XCTAssertNotNil(updated.activeSession?.activeTab)
    }

    func testLegacyTabsDecodeAsSeparateSessions() throws {
        let firstTab = Tab(id: UUID(), title: "Shell", cwd: "/Users/robert/Code/harness", sortOrder: 0)
        let secondTab = Tab(id: UUID(), title: "worker", cwd: "/tmp/api", sortOrder: 1)
        let workspaceID = UUID()
        let legacy = LegacySnapshot(
            version: 1,
            revision: 7,
            workspaces: [
                LegacyWorkspace(
                    id: workspaceID,
                    name: "Default",
                    tabs: [firstTab, secondTab],
                    activeTabID: secondTab.id,
                    sortOrder: 0
                ),
            ],
            activeWorkspaceID: workspaceID,
            themeName: "Dracula",
            keepSessionsOnQuit: true,
            savedAt: Date(timeIntervalSince1970: 10)
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)
        let workspace = try XCTUnwrap(decoded.activeWorkspace)

        XCTAssertEqual(decoded.version, SessionSnapshot.currentVersion)
        XCTAssertEqual(decoded.revision, 7)
        XCTAssertEqual(workspace.sessions.count, 2)
        XCTAssertEqual(workspace.activeSession?.tabs.first?.id, secondTab.id)
        XCTAssertEqual(workspace.sessions.map { $0.tabs.count }, [1, 1])
    }

    func testSplitNestedPaneUsesRequestedDirectionAndReturnsNewPane() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(workspace.activeTab)
        let rootPane = try XCTUnwrap(tab.rootPane.paneID)

        let firstNewPane = try XCTUnwrap(editor.splitPane(
            in: workspace.id,
            tabID: tab.id,
            paneID: rootPane,
            direction: .horizontal
        ))
        let secondNewPane = try XCTUnwrap(editor.splitPane(
            in: workspace.id,
            tabID: tab.id,
            paneID: firstNewPane,
            direction: .vertical
        ))

        let updated = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        XCTAssertTrue(updated.rootPane.allPaneIDs().contains(firstNewPane))
        XCTAssertTrue(updated.rootPane.allPaneIDs().contains(secondNewPane))

        guard case let .branch(rootDirection, _, _, second) = updated.rootPane else {
            return XCTFail("Expected root branch")
        }
        XCTAssertEqual(rootDirection, .horizontal)
        guard case let .branch(nestedDirection, _, _, _) = second else {
            return XCTFail("Expected nested branch")
        }
        XCTAssertEqual(nestedDirection, .vertical)
    }

    func testNotifyTargetsOnlyMatchingSurface() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let first = try XCTUnwrap(workspace.activeTab)
        _ = editor.addTab(to: workspace.id, cwd: "/tmp")
        let second = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)

        let match = try XCTUnwrap(editor.tab(forSurfaceKey: first.rootPane.allSurfaceIDs()[0].uuidString))
        editor.setTabStatus(workspaceID: match.workspaceID, tabID: match.tabID, status: .waiting, notificationText: "test")

        let tabs = try XCTUnwrap(editor.snapshot.activeWorkspace?.tabs)
        XCTAssertEqual(tabs.first(where: { $0.id == first.id })?.status, .waiting)
        XCTAssertEqual(tabs.first(where: { $0.id == second.id })?.status, .idle)
    }
}

private struct LegacySnapshot: Codable {
    var version: Int
    var revision: Int
    var workspaces: [LegacyWorkspace]
    var activeWorkspaceID: WorkspaceID?
    var themeName: String
    var keepSessionsOnQuit: Bool
    var savedAt: Date
}

private struct LegacyWorkspace: Codable {
    var id: WorkspaceID
    var name: String
    var tabs: [Tab]
    var activeTabID: TabID?
    var sortOrder: Int
}
