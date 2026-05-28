import XCTest
@testable import HarnessCore

final class CommandParserTests: XCTestCase {
    func testParsesPaneActions() throws {
        XCTAssertEqual(try CommandParser.parse("kill-pane"), .killPane)
        XCTAssertEqual(try CommandParser.parse("zoom-pane"), .zoomPane)
        XCTAssertEqual(try CommandParser.parse("split-window"), .splitWindow(direction: .vertical))
        XCTAssertEqual(try CommandParser.parse("split-window -v"), .splitWindow(direction: .horizontal))
        XCTAssertEqual(try CommandParser.parse("split-window -h"), .splitWindow(direction: .vertical))
        XCTAssertEqual(try CommandParser.parse("select-pane -L"), .selectPane(target: .left))
        XCTAssertEqual(try CommandParser.parse("resize-pane -R 5"), .resizePane(direction: .right, amount: 5))
        XCTAssertEqual(try CommandParser.parse("resize-pane -Z"), .zoomPane)
    }

    func testParsesNavigationAndSessions() throws {
        XCTAssertEqual(try CommandParser.parse("next-window"), .nextWindow)
        XCTAssertEqual(try CommandParser.parse("previous-window"), .previousWindow)
        XCTAssertEqual(try CommandParser.parse("select-window 3"), .selectWindow(index: 3))
        XCTAssertEqual(try CommandParser.parse("new-session"), .newSession(name: nil))
        XCTAssertEqual(try CommandParser.parse("new-session -s api"), .newSession(name: "api"))
        XCTAssertEqual(try CommandParser.parse("select-workspace 2"), .selectWorkspace(index: 2))
    }

    func testParsesSequences() throws {
        let parsed = try CommandParser.parse("split-window -h ; copy-mode")
        XCTAssertEqual(parsed, .sequence([
            .splitWindow(direction: .vertical),
            .copyMode,
        ]))
    }

    func testQuotedStringsArePreserved() throws {
        let parsed = try CommandParser.parse(#"display-message "tab #{tab_name} ready""#)
        XCTAssertEqual(parsed, .displayMessage(format: "tab #{tab_name} ready"))
    }

    func testBindKeyParsesNestedCommand() throws {
        let parsed = try CommandParser.parse("bind-key -T prefix S split-window -v")
        XCTAssertEqual(parsed, .bindKey(
            table: "prefix",
            spec: "S",
            command: .splitWindow(direction: .horizontal)
        ))
    }

    func testUnknownCommandThrowsClearError() {
        XCTAssertThrowsError(try CommandParser.parse("yoink")) { error in
            guard let error = error as? CommandParseError else {
                return XCTFail("expected CommandParseError, got \(error)")
            }
            XCTAssertEqual(error, .unknownCommand("yoink"))
        }
    }

    func testRoundTripJSONForCodableCommand() throws {
        let original: Command = .sequence([
            .splitWindow(direction: .horizontal),
            .selectPane(target: .left),
            .bindKey(table: "prefix", spec: "C-x q", command: .detachClient),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Command.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
