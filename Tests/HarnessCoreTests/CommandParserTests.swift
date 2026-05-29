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

    func testUniversalTargetWrapsCommand() throws {
        XCTAssertEqual(
            try CommandParser.parse("kill-pane -t :2"),
            .targeted(TargetSpec(window: .byIndex(2), raw: ":2"), .killPane)
        )
        XCTAssertEqual(
            try CommandParser.parse("split-window -h -t api:1"),
            .targeted(TargetSpec(session: .byName("api"), window: .byIndex(1), raw: "api:1"),
                      .splitWindow(direction: .vertical))
        )
        XCTAssertEqual(
            try CommandParser.parse("new-window -t api:"),
            .targeted(TargetSpec(session: .byName("api"), raw: "api:"), .newWindow)
        )
    }

    func testSelectWindowTargetForms() throws {
        // Bare index and `:index` keep the plain form (no regression).
        XCTAssertEqual(try CommandParser.parse("select-window 3"), .selectWindow(index: 3))
        XCTAssertEqual(try CommandParser.parse("select-window -t :3"), .selectWindow(index: 3))
        // Session-qualified resolves centrally.
        XCTAssertEqual(
            try CommandParser.parse("select-window -t api:2"),
            .targeted(TargetSpec(session: .byName("api"), window: .byIndex(2), raw: "api:2"),
                      .selectWindow(index: 2))
        )
    }

    func testSendKeysDoesNotLeakTargetValue() throws {
        // The `-t` value must be stripped, not collected as a key.
        XCTAssertEqual(
            try CommandParser.parse("send-keys -t api:1.0 Enter"),
            .targeted(TargetSpec(session: .byName("api"), window: .byIndex(1), pane: .byIndex(0), raw: "api:1.0"),
                      .sendKeys(keys: ["Enter"]))
        )
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
            command: .splitWindow(direction: .horizontal),
            repeatable: false
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
            .bindKey(table: "prefix", spec: "C-x q", command: .detachClient, repeatable: false),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Command.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testBindKeyRepeatableFlag() throws {
        let parsed = try CommandParser.parse("bind-key -r -T prefix C-j resize-pane -D 5")
        XCTAssertEqual(parsed, .bindKey(
            table: "prefix",
            spec: "C-j",
            command: .resizePane(direction: .down, amount: 5),
            repeatable: true
        ))
    }

    func testRunShellBackgroundAndIfShell() throws {
        XCTAssertEqual(
            try CommandParser.parse("run-shell -b 'echo hi'"),
            .runShell(shellCommand: "echo hi", captureToBuffer: true)
        )
        XCTAssertEqual(
            try CommandParser.parse("if-shell 'test -f x' 'kill-pane' 'detach-client'"),
            .ifShell(condition: "test -f x", then: .killPane, otherwise: .detachClient)
        )
    }

    func testMarkAndJoinAndMoveWindow() throws {
        XCTAssertEqual(try CommandParser.parse("select-pane -m"), .markPane(set: true))
        XCTAssertEqual(try CommandParser.parse("select-pane -M"), .markPane(set: false))
        XCTAssertEqual(try CommandParser.parse("join-pane -h"), .joinPane(direction: .vertical))
        XCTAssertEqual(try CommandParser.parse("move-window -t :2"), .moveWindow(toIndex: 2))
        XCTAssertEqual(try CommandParser.parse("select-pane -l"), .selectPane(target: .last))
    }
}
