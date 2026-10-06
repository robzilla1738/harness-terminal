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
        XCTAssertEqual(titles["action.addRemoteHost"]?.title, "Add Remote Host...")
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
        XCTAssertTrue(rows.contains { $0.id == "action.addRemoteHost" && $0.title == "Add Remote Host..." })
    }
}
