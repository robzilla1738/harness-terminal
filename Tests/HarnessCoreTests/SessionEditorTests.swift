import XCTest
@testable import HarnessCore

final class SessionEditorTests: XCTestCase {
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
