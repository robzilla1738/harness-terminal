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

    func testInvalidSelectionDoesNotMutateSnapshot() throws {
        var editor = SessionEditor()
        let original = editor.snapshot

        XCTAssertFalse(editor.selectWorkspace(UUID()))
        XCTAssertFalse(editor.selectSession(workspaceID: UUID(), sessionID: UUID()))
        XCTAssertFalse(editor.selectTab(workspaceID: UUID(), tabID: UUID()))
        XCTAssertEqual(editor.snapshot, original)
    }

    func testThemeAndKeepSessionsBumpRevisionOnlyWhenChanged() {
        var editor = SessionEditor()
        let originalRevision = editor.snapshot.revision

        editor.setTheme("Dracula")
        XCTAssertEqual(editor.snapshot.themeName, "Dracula")
        XCTAssertEqual(editor.snapshot.revision, originalRevision + 1)

        editor.setTheme("Dracula")
        XCTAssertEqual(editor.snapshot.revision, originalRevision + 1)

        editor.setKeepSessionsOnQuit(!editor.snapshot.keepSessionsOnQuit)
        XCTAssertEqual(editor.snapshot.revision, originalRevision + 2)
    }

    func testReorderTabMovesTabToRequestedIndex() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        _ = editor.addTab(to: workspace.id, cwd: "/tmp")
        _ = editor.addTab(to: workspace.id, cwd: "/tmp")
        let before = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs)
        XCTAssertEqual(before.count, 3)
        let firstID = before[0].id

        XCTAssertTrue(editor.reorderTab(workspaceID: workspace.id, tabID: firstID, toIndex: 2))

        let after = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs)
        XCTAssertEqual(after.map(\.id), [before[1].id, before[2].id, firstID])
    }

    func testSetSplitRatioUpdatesAndClampsBranch() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(workspace.activeTab)
        let root = try XCTUnwrap(tab.rootPane.paneID)
        _ = try XCTUnwrap(editor.splitPane(in: workspace.id, tabID: tab.id, paneID: root, direction: .horizontal))

        let split = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        guard case let .branch(_, ratio0, first, second) = split.rootPane else { return XCTFail("expected branch") }
        XCTAssertEqual(ratio0, 0.5, accuracy: 0.0001)
        let firstLeaf = try XCTUnwrap(first.paneID)
        let secondLeaf = try XCTUnwrap(second.paneID)

        XCTAssertTrue(editor.setSplitRatio(tabID: tab.id, firstPaneID: firstLeaf, secondPaneID: secondLeaf, ratio: 0.7))
        guard case let .branch(_, ratio1, _, _) = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab).rootPane else {
            return XCTFail("expected branch")
        }
        XCTAssertEqual(ratio1, 0.7, accuracy: 0.0001)

        // Out-of-range ratio clamps to [0.1, 0.9]; unknown panes are a no-op.
        XCTAssertTrue(editor.setSplitRatio(tabID: tab.id, firstPaneID: firstLeaf, secondPaneID: secondLeaf, ratio: 0.99))
        guard case let .branch(_, ratio2, _, _) = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab).rootPane else {
            return XCTFail("expected branch")
        }
        XCTAssertEqual(ratio2, 0.9, accuracy: 0.0001)
        XCTAssertFalse(editor.setSplitRatio(tabID: tab.id, firstPaneID: UUID(), secondPaneID: UUID(), ratio: 0.5))
    }

    func testSurfaceIDForPaneIDResolvesLeaves() throws {
        let editor = SessionEditor()
        let tab = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        guard case let .leaf(leaf) = tab.rootPane else { return XCTFail("expected single leaf") }
        XCTAssertEqual(editor.surfaceID(forPaneID: leaf.id), leaf.surfaceID)
        XCTAssertNil(editor.surfaceID(forPaneID: UUID()))
    }

    func testKillPaneCollapsesBranchToSurvivor() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(workspace.activeTab)
        let root = try XCTUnwrap(tab.rootPane.paneID)
        let newPane = try XCTUnwrap(editor.splitPane(in: workspace.id, tabID: tab.id, paneID: root, direction: .horizontal))
        XCTAssertEqual(try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab).rootPane.allPaneIDs().count, 2)

        XCTAssertTrue(editor.killPane(newPane))

        let after = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        XCTAssertEqual(after.rootPane.allPaneIDs(), [root])
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
