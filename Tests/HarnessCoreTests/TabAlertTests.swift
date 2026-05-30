import XCTest
@testable import HarnessCore

/// Phase 5: tab monitoring alert flags (`#`/`~`/`!`), clear-on-view, and tolerant decode.
final class TabAlertTests: XCTestCase {
    private func makeEditor() -> (editor: SessionEditor, ws: WorkspaceID, t1: TabID, t2: TabID) {
        let t1 = Tab(id: UUID(), title: "one", sortOrder: 0)
        let t2 = Tab(id: UUID(), title: "two", sortOrder: 1)
        let sess = SessionGroup(id: UUID(), name: "s", tabs: [t1, t2], activeTabID: t1.id, sortOrder: 0)
        let ws = Workspace(id: UUID(), name: "W", sessions: [sess], activeSessionID: sess.id)
        var editor = SessionEditor()
        editor.snapshot = SessionSnapshot(workspaces: [ws], activeWorkspaceID: ws.id)
        return (editor, ws.id, t1.id, t2.id)
    }

    private func tab(_ editor: SessionEditor, _ id: TabID) -> Tab? {
        editor.snapshot.workspaces.flatMap { $0.sessions }.flatMap { $0.tabs }.first { $0.id == id }
    }

    func testSetAlertsOnlyChangesProvidedFlags() {
        var (editor, ws, _, t2) = makeEditor()
        XCTAssertTrue(editor.setTabAlerts(workspaceID: ws, tabID: t2, activity: true, bell: true))
        XCTAssertEqual(tab(editor, t2)?.alertFlags, "#!")
        // Setting the same value again is a no-op (returns false).
        XCTAssertFalse(editor.setTabAlerts(workspaceID: ws, tabID: t2, activity: true))
        XCTAssertTrue(editor.setTabAlerts(workspaceID: ws, tabID: t2, silence: true))
        XCTAssertEqual(tab(editor, t2)?.alertFlags, "#~!")
    }

    func testTabIsCurrent() {
        let (editor, ws, t1, t2) = makeEditor()
        XCTAssertTrue(editor.tabIsCurrent(workspaceID: ws, tabID: t1))  // active tab
        XCTAssertFalse(editor.tabIsCurrent(workspaceID: ws, tabID: t2))
    }

    func testSelectTabClearsAlerts() {
        var (editor, ws, _, t2) = makeEditor()
        editor.setTabAlerts(workspaceID: ws, tabID: t2, activity: true, silence: true, bell: true)
        XCTAssertEqual(tab(editor, t2)?.alertFlags, "#~!")
        XCTAssertTrue(editor.selectTab(workspaceID: ws, tabID: t2))
        XCTAssertEqual(tab(editor, t2)?.alertFlags, "") // viewing clears
    }

    func testAlertFlagString() {
        XCTAssertEqual(Tab(title: "x").alertFlags, "")
        XCTAssertEqual(Tab(title: "x", activity: true, bell: true).alertFlags, "#!")
    }

    func testToleratesOldJSONWithoutAlertFields() throws {
        let original = Tab(title: "t")
        let data = try JSONEncoder().encode(original)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["activity", "silence", "bell", "exitStatus"] { obj.removeValue(forKey: key) }
        let stripped = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try JSONDecoder().decode(Tab.self, from: stripped)
        XCTAssertFalse(decoded.activity)
        XCTAssertFalse(decoded.silence)
        XCTAssertFalse(decoded.bell)
        XCTAssertNil(decoded.exitStatus)
    }
}
