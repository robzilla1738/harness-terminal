import XCTest
@testable import HarnessCore

final class ChromeMenuTests: XCTestCase {
    func testCommandMenuKeepsActionsAndMarksTheSelectedRow() {
        let rows = ChromeMenus.commandRows(selectedID: "action.newTab")
        let titles = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertEqual(titles["action.newSession"]?.title, "New Session")
        XCTAssertEqual(titles["action.newSession"]?.shortcut, "⇧⌘N")
        XCTAssertEqual(titles["action.newTab"]?.shortcut, "⌘T")
        XCTAssertEqual(titles["action.splitH"]?.title, "Split Horizontal")
        XCTAssertEqual(titles["action.settings"]?.shortcut, "⌘,")
        XCTAssertEqual(titles["action.addRemoteHost"]?.title, "Add Remote Host…")
        let selected = rows.filter(\.selected)
        XCTAssertEqual(selected.map(\.id), ["action.newTab"])
        XCTAssertFalse(rows.filter { $0.id != "action.newTab" }.contains(where: \.selected))
    }

    func testSessionListMarksCurrentAndKeepsCreateActions() {
        let rows = ChromeMenus.sessionRows(
            sessions: [("a", "~/Code/harness"), ("b", "~")],
            currentID: "b",
            selectedID: "a"
        )
        XCTAssertTrue(rows.contains { $0.id == "b" && $0.current && $0.title == "~" })
        XCTAssertTrue(rows.contains { $0.id == "a" && $0.selected && !$0.current })
        XCTAssertTrue(rows.contains { $0.id == "action.newSession" && $0.title == "New Session" })
        XCTAssertTrue(rows.contains { $0.id == "action.addRemoteHost" && $0.title == "Add Remote Host…" })
    }

    func testSwitcherFiltersOffersCreateAndSeparatesActions() {
        let sessions = [
            SwitcherSession(id: "a", title: "Demo", owner: "local", ownerTitle: "This Mac"),
            SwitcherSession(id: "b", title: "Work", owner: "local", ownerTitle: "This Mac"),
        ]
        let all = SessionSwitcherModel.items(sessions: sessions, currentID: "a", query: "")
        XCTAssertEqual(all.compactMap(\.row?.id), ["a", "b", "action.newSession", "action.addRemoteHost"])
        XCTAssertEqual(all.filter { $0 == .separator }.count, 2)
        XCTAssertFalse(all.contains { if case .header = $0 { return true }; return false }, "one daemon, no headers")
        XCTAssertEqual(SessionSwitcherModel.initialSelection(all, query: "", currentID: "a"), 0)

        let typed = SessionSwitcherModel.items(sessions: sessions, currentID: "a", query: "api")
        XCTAssertEqual(typed.compactMap(\.row?.id), ["action.createSession", "action.newSession", "action.addRemoteHost"])
        XCTAssertEqual(typed.first?.row?.title, "Create \u{201C}api\u{201D}")
        XCTAssertEqual(SessionSwitcherModel.initialSelection(typed, query: "api", currentID: "a"), 0)

        let exact = SessionSwitcherModel.items(sessions: sessions, currentID: "a", query: "work")
        XCTAssertEqual(exact.compactMap(\.row?.id), ["b", "action.newSession", "action.addRemoteHost"])
    }

    func testSwitcherGroupsByDaemonAndStepsOverSeparators() {
        let sessions = [
            SwitcherSession(id: "a", title: "Demo", owner: "local", ownerTitle: "This Mac"),
            SwitcherSession(id: "r", title: "Build", owner: "devbox", ownerTitle: "devbox"),
        ]
        let items = SessionSwitcherModel.items(sessions: sessions, currentID: "a", query: "")
        XCTAssertEqual(items.first, .header("This Mac"))
        XCTAssertTrue(items.contains(.header("devbox")))
        let first = SessionSwitcherModel.step(items, from: nil, by: 1)
        XCTAssertEqual(items[first!].row?.id, "a")
        let second = SessionSwitcherModel.step(items, from: first, by: 1)
        XCTAssertEqual(items[second!].row?.id, "r")
        let wrapped = SessionSwitcherModel.step(items, from: first, by: -1)
        XCTAssertEqual(items[wrapped!].row?.id, "action.addRemoteHost")
    }
}
