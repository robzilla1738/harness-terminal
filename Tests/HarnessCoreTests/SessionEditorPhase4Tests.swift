import XCTest
@testable import HarnessCore

final class SessionEditorPhase4Tests: XCTestCase {
    /// Convenience: hand back the workspace + tab IDs for the default
    /// (auto-created) tab in a fresh editor. Phase 4 tests operate on that
    /// tab so we don't have to thread our own workspace identifier through.
    private func defaultTab(_ editor: SessionEditor) throws -> (workspaceID: WorkspaceID, tabID: TabID, rootPaneID: PaneID) {
        let workspace = try XCTUnwrap(editor.snapshot.activeWorkspace)
        let tab = try XCTUnwrap(workspace.activeTab)
        let pane = try XCTUnwrap(tab.rootPane.paneID)
        return (workspace.id, tab.id, pane)
    }

    func testDirectionalSelectFindsUpwardNeighbor() throws {
        var editor = SessionEditor()
        let (ws, tabID, original) = try defaultTab(editor)
        let newPane = try XCTUnwrap(editor.splitPane(
            in: ws, tabID: tabID, paneID: original, direction: .horizontal
        ))
        // .horizontal in our enum → horizontal divider, top/bottom panes. The
        // original pane is on top; the new pane is on the bottom.
        XCTAssertEqual(editor.directionalNeighbor(of: newPane, direction: .up), original)
        XCTAssertEqual(editor.directionalNeighbor(of: original, direction: .down), newPane)
    }

    func testDirectionalSelectReturnsNilWithoutNeighbor() throws {
        let editor = SessionEditor()
        let (_, _, only) = try defaultTab(editor)
        XCTAssertNil(editor.directionalNeighbor(of: only, direction: .left))
    }

    func testApplyLayoutPreservesSurfaceCount() throws {
        var editor = SessionEditor()
        let (ws, tabID, original) = try defaultTab(editor)
        _ = editor.splitPane(in: ws, tabID: tabID, paneID: original, direction: .vertical)
        let secondPane = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeTab?.rootPane.allPaneIDs().last)
        _ = editor.splitPane(in: ws, tabID: tabID, paneID: secondPane, direction: .horizontal)
        let before = (editor.snapshot.activeWorkspace?.activeTab?.rootPane.allSurfaceIDs() ?? []).sorted()
        XCTAssertTrue(editor.applyLayout(tabID: tabID, layout: .tiled, mainPaneID: nil))
        let after = (editor.snapshot.activeWorkspace?.activeTab?.rootPane.allSurfaceIDs() ?? []).sorted()
        XCTAssertEqual(before, after, "tiled must reuse the existing surfaces")
    }

    func testBreakPaneMovesPaneToNewTab() throws {
        var editor = SessionEditor()
        let (ws, tabID, original) = try defaultTab(editor)
        let secondPane = try XCTUnwrap(editor.splitPane(
            in: ws, tabID: tabID, paneID: original, direction: .vertical
        ))
        let tabsBefore = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs.count)
        let newTabID = editor.breakPane(paneID: secondPane)
        XCTAssertNotNil(newTabID)
        let tabsAfter = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs.count)
        XCTAssertEqual(tabsAfter, tabsBefore + 1)
        // Original tab now has just the surviving pane.
        let origTab = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs.first { $0.id == tabID })
        XCTAssertEqual(origTab.rootPane.allPaneIDs(), [original])
    }

    func testBreakPaneRefusesWhenOnlyOnePane() throws {
        var editor = SessionEditor()
        let (_, _, lone) = try defaultTab(editor)
        XCTAssertNil(editor.breakPane(paneID: lone))
    }

    /// joinPane with an unknown destination must be a complete no-op. It previously removed
    /// the source pane from its tab BEFORE the destination lookup and returned nil without
    /// rollback — silently corrupting the persistent editor snapshot while the caller saw
    /// "Cannot join pane".
    func testJoinPaneWithUnknownDestinationLeavesSnapshotUnchanged() throws {
        var editor = SessionEditor()
        let (ws, tabID, original) = try defaultTab(editor)
        let secondPane = try XCTUnwrap(editor.splitPane(
            in: ws, tabID: tabID, paneID: original, direction: .vertical
        ))
        let revisionBefore = editor.snapshot.revision
        XCTAssertNil(editor.joinPane(sourcePaneID: secondPane, destPaneID: UUID(), direction: .horizontal))
        let tab = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs.first { $0.id == tabID })
        XCTAssertEqual(Set(tab.rootPane.allPaneIDs()), Set([original, secondPane]),
                       "a refused join must not drop the source pane")
        XCTAssertEqual(editor.snapshot.revision, revisionBefore, "no revision bump on a refused join")
    }

    func testJoinPaneRefusesSamePane() throws {
        var editor = SessionEditor()
        let (ws, tabID, original) = try defaultTab(editor)
        let secondPane = try XCTUnwrap(editor.splitPane(
            in: ws, tabID: tabID, paneID: original, direction: .vertical
        ))
        XCTAssertNil(editor.joinPane(sourcePaneID: secondPane, destPaneID: secondPane, direction: .horizontal))
        let tab = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs.first { $0.id == tabID })
        XCTAssertEqual(Set(tab.rootPane.allPaneIDs()), Set([original, secondPane]),
                       "src == dst must refuse without mutating")
    }

    func testJoinPaneMovesPaneIntoDestinationTab() throws {
        var editor = SessionEditor()
        let (ws, tabID, original) = try defaultTab(editor)
        let secondPane = try XCTUnwrap(editor.splitPane(
            in: ws, tabID: tabID, paneID: original, direction: .vertical
        ))
        // Carve the second pane into its own tab, split it there, then join the new
        // sibling back next to `original` — a multi-pane source tab, as required.
        let newTabID = try XCTUnwrap(editor.breakPane(paneID: secondPane))
        let movedPane = try XCTUnwrap(
            editor.snapshot.activeWorkspace?.activeSession?.tabs
                .first { $0.id == newTabID }?.rootPane.allPaneIDs().first
        )
        let sibling = try XCTUnwrap(editor.splitPane(
            in: ws, tabID: newTabID, paneID: movedPane, direction: .horizontal
        ))
        let joined = try XCTUnwrap(editor.joinPane(
            sourcePaneID: sibling, destPaneID: original, direction: .horizontal
        ))
        let destTab = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs.first { $0.id == tabID })
        XCTAssertTrue(destTab.rootPane.allPaneIDs().contains(joined), "joined pane lands in the destination tab")
        XCTAssertEqual(destTab.rootPane.allPaneIDs().count, 2)
        let sourceTab = try XCTUnwrap(editor.snapshot.activeWorkspace?.activeSession?.tabs.first { $0.id == newTabID })
        XCTAssertEqual(sourceTab.rootPane.allPaneIDs(), [movedPane], "source tab keeps only the remaining pane")
    }

    func testLayoutTemplateCycleIsRoundTrip() {
        XCTAssertEqual(LayoutTemplate.evenHorizontal.next(), .evenVertical)
        XCTAssertEqual(LayoutTemplate.evenVertical.previous(), .evenHorizontal)
        var current = LayoutTemplate.evenHorizontal
        for _ in 0..<LayoutTemplate.allCases.count { current = current.next() }
        XCTAssertEqual(current, .evenHorizontal)
    }
}
