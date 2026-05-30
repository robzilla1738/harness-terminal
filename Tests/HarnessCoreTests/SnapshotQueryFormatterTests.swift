import XCTest
@testable import HarnessCore

final class SnapshotQueryFormatterTests: XCTestCase {
    /// Build a snapshot with one workspace, two named sessions; the second has two tabs and the
    /// first tab has a split (two panes).
    private func makeSnapshot() -> SessionSnapshot {
        var editor = SessionEditor()
        let ws = editor.snapshot.activeWorkspace!.id
        // Rename the seeded session and add a second.
        let first = editor.snapshot.activeWorkspace!.sessions[0].id
        _ = editor.renameSession(first, name: "alpha")
        let second = editor.addSession(to: ws, name: "beta")!
        _ = editor.addTab(to: ws) // second session gets a 2nd tab (active session is `beta`)
        // Split the active tab of beta so list-panes has >1 pane.
        let tab = editor.snapshot.activeWorkspace!.sessions.first { $0.id == second }!.activeTab!
        let pane = tab.rootPane.allPaneIDs().first!
        _ = editor.splitPane(in: ws, tabID: tab.id, paneID: pane, direction: .vertical)
        return editor.snapshot
    }

    func testSessionsListsEachWithWindowCount() {
        let lines = SnapshotQueryFormatter.sessions(makeSnapshot())
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("alpha") && $0.contains("(1 windows)") })
        XCTAssertTrue(lines.contains { $0.contains("beta") && $0.contains("(2 windows)") })
    }

    func testWindowsEnumeratesAllTabs() {
        let snap = makeSnapshot()
        XCTAssertEqual(SnapshotQueryFormatter.windows(snap).count, 3) // 1 (alpha) + 2 (beta)
        let beta = snap.workspaces.flatMap(\.sessions).first { $0.name == "beta" }!
        XCTAssertEqual(SnapshotQueryFormatter.windows(in: beta).count, 2)
    }

    func testPanesIndexedWithActiveFlag() {
        let snap = makeSnapshot()
        let beta = snap.workspaces.flatMap(\.sessions).first { $0.name == "beta" }!
        let lines = SnapshotQueryFormatter.panes(in: beta.activeTab!)
        XCTAssertEqual(lines.count, 2, "the split produced two panes")
        XCTAssertTrue(lines[0].hasPrefix("0: "))
        XCTAssertEqual(lines.filter { $0.contains("(active)") }.count, 1, "exactly one active pane")
    }

    func testSessionExistsByNameAndID() {
        let snap = makeSnapshot()
        XCTAssertTrue(SnapshotQueryFormatter.sessionExists(snap, nameOrID: "alpha"))
        let id = snap.workspaces.flatMap(\.sessions).first { $0.name == "beta" }!.id.uuidString
        XCTAssertTrue(SnapshotQueryFormatter.sessionExists(snap, nameOrID: id))
        XCTAssertTrue(SnapshotQueryFormatter.sessionExists(snap, nameOrID: id.uppercased()))
        XCTAssertFalse(SnapshotQueryFormatter.sessionExists(snap, nameOrID: "nope"))
    }
}
