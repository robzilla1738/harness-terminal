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

    func testLayoutTemplateCycleIsRoundTrip() {
        XCTAssertEqual(LayoutTemplate.evenHorizontal.next(), .evenVertical)
        XCTAssertEqual(LayoutTemplate.evenVertical.previous(), .evenHorizontal)
        var current = LayoutTemplate.evenHorizontal
        for _ in 0..<LayoutTemplate.allCases.count { current = current.next() }
        XCTAssertEqual(current, .evenHorizontal)
    }
}
