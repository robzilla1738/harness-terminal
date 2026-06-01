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

    func testMovePaneAndRenumberParsing() throws {
        XCTAssertEqual(
            try CommandParser.parse("move-pane -s api:1.0"),
            .movePane(direction: .vertical,
                      source: TargetSpec(session: .byName("api"), window: .byIndex(1), pane: .byIndex(0), raw: "api:1.0"))
        )
        XCTAssertEqual(try CommandParser.parse("move-pane -v -s :2"),
                       .movePane(direction: .horizontal, source: TargetSpec(window: .byIndex(2), raw: ":2")))
        XCTAssertEqual(try CommandParser.parse("renumber-windows"), .renumberWindows)
    }

    func testCopyModeActionParsing() throws {
        XCTAssertEqual(try CommandParser.parse("copy-mode"), .copyMode)
        XCTAssertEqual(try CommandParser.parse("copy-mode -X cursor-left"), .copyModeCommand(.cursorLeft))
        XCTAssertEqual(try CommandParser.parse("copy-mode -X begin-selection"), .copyModeCommand(.beginSelection))
        XCTAssertEqual(try CommandParser.parse("copy-mode -X rectangle-toggle"), .copyModeCommand(.rectangleToggle))
        XCTAssertEqual(try CommandParser.parse("send-keys -X cursor-up"), .copyModeCommand(.cursorUp))
        XCTAssertEqual(try CommandParser.parse(#"copy-mode -X copy-pipe "pbcopy""#), .copyModeCommand(.copyPipe("pbcopy")))
    }

    func testCopyModeKeyTableIsRebindableVocabulary() {
        let copyTable = KeyTableSet.defaults.table(.copyMode)
        // Real copy-mode commands, not display-message placeholders.
        XCTAssertEqual(copyTable?.lookup(KeySpec(key: "v"))?.command, .copyModeCommand(.beginSelection))
        XCTAssertEqual(copyTable?.lookup(KeySpec(key: "v", modifiers: .control))?.command, .copyModeCommand(.rectangleToggle))
        XCTAssertEqual(copyTable?.lookup(KeySpec(key: "y"))?.command, .copyModeCommand(.copySelectionAndCancel))
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

    func testPaneCycleConvenienceVerbs() throws {
        XCTAssertEqual(try CommandParser.parse("next-pane"), .selectPane(target: .next))
        XCTAssertEqual(try CommandParser.parse("previous-pane"), .selectPane(target: .previous))
        XCTAssertEqual(try CommandParser.parse("last-pane"), .selectPane(target: .last))
    }

    // MARK: - Robustness (audit Tier 1.5)

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try CommandParser.parse(#"display-message "hello"#)) { error in
            XCTAssertEqual(error as? CommandParseError, .unterminatedString)
        }
        // A properly terminated quote still parses (no regression).
        XCTAssertEqual(try CommandParser.parse(#"display-message "hello""#), .displayMessage(format: "hello"))
    }

    func testMovePaneRequiresSource() {
        XCTAssertThrowsError(try CommandParser.parse("move-pane")) { error in
            XCTAssertEqual(error as? CommandParseError, .missingArgument("move-pane requires -s <source>"))
        }
        // Direction flag but still no source.
        XCTAssertThrowsError(try CommandParser.parse("move-pane -v"))
    }

    func testCommandPromptParsing() throws {
        XCTAssertEqual(
            try CommandParser.parse(#"command-prompt -p "name" "rename-window %%""#),
            .commandPrompt(prompts: ["name"], template: "rename-window %%")
        )
        // The template token equals the -p prompt value: position-based parsing must keep it
        // (the old value-comparison dropped it, yielding an empty template).
        XCTAssertEqual(
            try CommandParser.parse(#"command-prompt -p "rename" "rename""#),
            .commandPrompt(prompts: ["rename"], template: "rename")
        )
    }

    func testConfirmBeforeParsing() throws {
        XCTAssertEqual(
            try CommandParser.parse(#"confirm-before -p "Kill?" kill-pane"#),
            .confirmBefore(prompt: "Kill?", command: .killPane)
        )
        // A command token equal to the -p prompt value must not be filtered out (the old
        // value-comparison dropped it, throwing "requires a command").
        XCTAssertEqual(
            try CommandParser.parse(#"confirm-before -p "kill-pane" kill-pane"#),
            .confirmBefore(prompt: "kill-pane", command: .killPane)
        )
    }

    func testDisplayMenuParsesItemTriples() throws {
        XCTAssertEqual(
            try CommandParser.parse(#"display-menu -T "Menu" "Item A" a kill-pane "Item B" b zoom-pane"#),
            .displayMenu(items: [
                .init(title: "Item A", key: "a", command: .killPane),
                .init(title: "Item B", key: "b", command: .zoomPane),
            ])
        )
        // An empty key string means "no key".
        XCTAssertEqual(
            try CommandParser.parse(#"display-menu "Only" "" kill-pane"#),
            .displayMenu(items: [.init(title: "Only", key: nil, command: .killPane)])
        )
    }

    func testKnownVerbsAreAllParseable() {
        // Drift guard: every verb advertised by `list-commands` must be one the parser actually
        // accepts. A verb may still throw missing-arg/flag (it needs operands) — that proves it's
        // known; only `.unknownCommand` is a failure.
        for verb in CommandParser.knownVerbs {
            do {
                _ = try CommandParser.parse(verb)
            } catch CommandParseError.unknownCommand(let name) {
                XCTFail("knownVerbs lists \(verb) but the parser rejects it as unknown (\(name))")
            } catch {
                // Other parse errors (missing arg/flag) are fine — the verb is recognized.
            }
        }
    }
}
