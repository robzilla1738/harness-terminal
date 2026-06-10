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

    // MARK: - Server-side active pane (Phase 2)

    func testSplitFocusesNewPane() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(ws.activeTab)
        let firstPane = try XCTUnwrap(tab.rootPane.allPaneIDs().first)
        let newPane = try XCTUnwrap(editor.splitPane(in: ws.id, tabID: tab.id, paneID: firstPane, direction: .vertical))
        let updated = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        XCTAssertEqual(updated.activePaneID, newPane, "focus follows the split")
        XCTAssertEqual(updated.lastActivePaneID, firstPane, "previous pane becomes MRU")
    }

    func testKillActivePanePromotesMRU() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(ws.activeTab)
        let firstPane = try XCTUnwrap(tab.rootPane.allPaneIDs().first)
        let newPane = try XCTUnwrap(editor.splitPane(in: ws.id, tabID: tab.id, paneID: firstPane, direction: .vertical))
        XCTAssertTrue(editor.killPane(newPane))
        let updated = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        XCTAssertEqual(updated.activePaneID, firstPane, "killing the active pane promotes the MRU pane")
        XCTAssertNil(updated.lastActivePaneID)
    }

    func testSetActivePaneTracksMRUAndValidatesMembership() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(ws.activeTab)
        let a = try XCTUnwrap(tab.rootPane.allPaneIDs().first)
        let b = try XCTUnwrap(editor.splitPane(in: ws.id, tabID: tab.id, paneID: a, direction: .horizontal))

        XCTAssertTrue(editor.setActivePane(workspaceID: ws.id, tabID: tab.id, paneID: a))
        var t = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        XCTAssertEqual(t.activePaneID, a)
        XCTAssertEqual(t.lastActivePaneID, b)

        XCTAssertTrue(editor.setActivePane(workspaceID: ws.id, tabID: tab.id, paneID: b))
        t = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        XCTAssertEqual(t.activePaneID, b)
        XCTAssertEqual(t.lastActivePaneID, a)

        XCTAssertFalse(editor.setActivePane(workspaceID: ws.id, tabID: tab.id, paneID: UUID()),
                       "a pane not in the tab is rejected")
    }

    func testPaneLocationResolvesSurfaceTabAndPaneCount() throws {
        // Used by remain-on-exit: a single-pane tab reports count 1 (→ close the tab);
        // a split reports count 2 (→ close just the pane).
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(ws.activeTab)
        let a = try XCTUnwrap(tab.rootPane.allPaneIDs().first)
        let surfA = try XCTUnwrap(editor.surfaceID(forPaneID: a))

        let loc1 = try XCTUnwrap(editor.paneLocation(forSurfaceKey: surfA.uuidString))
        XCTAssertEqual(loc1.tabID, tab.id)
        XCTAssertEqual(loc1.paneID, a)
        XCTAssertEqual(loc1.paneCount, 1)

        let b = try XCTUnwrap(editor.splitPane(in: ws.id, tabID: tab.id, paneID: a, direction: .horizontal))
        let surfB = try XCTUnwrap(editor.surfaceID(forPaneID: b))
        let loc2 = try XCTUnwrap(editor.paneLocation(forSurfaceKey: surfB.uuidString))
        XCTAssertEqual(loc2.paneID, b)
        XCTAssertEqual(loc2.paneCount, 2)

        XCTAssertNil(editor.paneLocation(forSurfaceKey: UUID().uuidString), "unknown surface → nil")
    }

    func testSwapPanesExchangesLeavesWithoutCorruption() throws {
        // Regression: two sequential id-keyed replaceLeaf passes used to destroy one
        // pane and duplicate the other (the second pass matched both copies of dst.id).
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(ws.activeTab)
        let a = try XCTUnwrap(tab.rootPane.allPaneIDs().first)
        let b = try XCTUnwrap(editor.splitPane(in: ws.id, tabID: tab.id, paneID: a, direction: .horizontal))
        let surfA = try XCTUnwrap(editor.surfaceID(forPaneID: a))
        let surfB = try XCTUnwrap(editor.surfaceID(forPaneID: b))

        let before = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        XCTAssertEqual(before.rootPane.allSurfaceIDs(), [surfA, surfB])

        XCTAssertTrue(editor.swapPanes(a, b))

        let after = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab)
        // Both panes survive — no pane destroyed, no id/surface duplicated.
        XCTAssertEqual(after.rootPane.allPaneIDs().count, 2, "no pane id dropped or duplicated")
        XCTAssertEqual(Set(after.rootPane.allPaneIDs()), [a, b])
        XCTAssertEqual(after.rootPane.allSurfaceIDs().count, 2, "no surface id dropped or duplicated")
        // Positions exchanged: first leaf now carries B's surface, second carries A's.
        XCTAssertEqual(after.rootPane.allSurfaceIDs(), [surfB, surfA])
    }

    func testSwapPanesAcrossTabsExchangesWithoutLoss() throws {
        var editor = SessionEditor()
        let ws = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab1 = try XCTUnwrap(ws.activeTab)
        let a = try XCTUnwrap(tab1.rootPane.allPaneIDs().first)
        let surfA = try XCTUnwrap(editor.surfaceID(forPaneID: a))
        let tab2ID = try XCTUnwrap(editor.addTab(to: ws.id, cwd: "/tmp"))
        let tab2 = try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.flatMap(\.tabs).first { $0.id == tab2ID })
        let b = try XCTUnwrap(tab2.rootPane.allPaneIDs().first)
        let surfB = try XCTUnwrap(editor.surfaceID(forPaneID: b))

        XCTAssertTrue(editor.swapPanes(a, b))

        let tabs = try XCTUnwrap(editor.snapshot.activeWorkspace?.sessions.flatMap(\.tabs))
        let t1 = try XCTUnwrap(tabs.first { $0.id == tab1.id })
        let t2 = try XCTUnwrap(tabs.first { $0.id == tab2ID })
        // A's surface moved to tab2, B's surface moved to tab1 — neither lost or duplicated.
        XCTAssertEqual(t1.rootPane.allSurfaceIDs(), [surfB])
        XCTAssertEqual(t2.rootPane.allSurfaceIDs(), [surfA])
    }

    /// v2 layout.json had no `activePaneID`/`lastActivePaneID`; decoding must backfill
    /// the focus to the first leaf so older files load with a valid active pane.
    func testTabDecodeBackfillsActivePaneFromV2() throws {
        let tab = Tab(title: "t", cwd: "/tmp")
        let data = try JSONEncoder().encode(tab)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "activePaneID")
        dict.removeValue(forKey: "lastActivePaneID")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(Tab.self, from: stripped)
        XCTAssertNotNil(decoded.activePaneID)
        XCTAssertEqual(decoded.activePaneID, decoded.rootPane.allPaneIDs().first)
        XCTAssertNil(decoded.lastActivePaneID)
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

    // MARK: - Git branch label (`setTabGitBranch`)

    func testSetTabGitBranchSetsClearsAndDedups() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(workspace.activeTab)

        XCTAssertTrue(editor.setTabGitBranch(workspaceID: workspace.id, tabID: tab.id, branch: "main"))
        XCTAssertEqual(editor.snapshot.activeWorkspace?.activeTab?.gitBranch, "main")
        let revisionAfterSet = editor.snapshot.revision

        // Idempotent re-send: no change, no revision bump (no subscriber wake-up).
        XCTAssertFalse(editor.setTabGitBranch(workspaceID: workspace.id, tabID: tab.id, branch: "main"))
        XCTAssertEqual(editor.snapshot.revision, revisionAfterSet)

        // `nil` CLEARS — a tab whose directory leaves a repository drops its stale label.
        XCTAssertTrue(editor.setTabGitBranch(workspaceID: workspace.id, tabID: tab.id, branch: nil))
        XCTAssertNil(editor.snapshot.activeWorkspace?.activeTab?.gitBranch)
        XCTAssertGreaterThan(editor.snapshot.revision, revisionAfterSet)

        // Clearing an already-clear label is also a no-op.
        XCTAssertFalse(editor.setTabGitBranch(workspaceID: workspace.id, tabID: tab.id, branch: nil))
    }

    func testSetTabGitBranchUnknownTabIsNoOp() throws {
        var editor = SessionEditor()
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let revision = editor.snapshot.revision
        XCTAssertFalse(editor.setTabGitBranch(workspaceID: workspace.id, tabID: UUID(), branch: "main"))
        XCTAssertEqual(editor.snapshot.revision, revision)
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
