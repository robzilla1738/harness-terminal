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

    func testRespawnPaneAcceptsBothClearHistoryForms() throws {
        // `-k` is the tmux-style grammar flag; `--clear-history` is the harness-cli long
        // form. Both must work in both layers so the docs can't be wrong.
        XCTAssertEqual(try CommandParser.parse("respawn-pane"), .respawnPane(keepHistory: true))
        XCTAssertEqual(try CommandParser.parse("respawn-pane -k"), .respawnPane(keepHistory: false))
        XCTAssertEqual(try CommandParser.parse("respawn-pane --clear-history"), .respawnPane(keepHistory: false))
    }

    func testParsesClearHistoryAndAlias() throws {
        // PR-18: `clear-history` clears scrollback WITHOUT respawning the shell (unlike
        // `respawn-pane -k`). The `clearhist` short alias matches tmux muscle memory.
        XCTAssertEqual(try CommandParser.parse("clear-history"), .clearHistory)
        XCTAssertEqual(try CommandParser.parse("clearhist"), .clearHistory)
        // It takes the universal `-t` like the other per-pane verbs — and so does the alias.
        // (A per-pane verb missing from `universalTargetCommands` would silently drop `-t` and
        // clear the *focused* pane: the strict-resolution footgun this guards against.)
        XCTAssertEqual(
            try CommandParser.parse("clear-history -t :2"),
            .targeted(TargetSpec(window: .byIndex(2), raw: ":2"), .clearHistory)
        )
        XCTAssertEqual(
            try CommandParser.parse("clearhist -t :2"),
            .targeted(TargetSpec(window: .byIndex(2), raw: ":2"), .clearHistory)
        )
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

    func testPaneTargetSpecialFormsParse() throws {
        XCTAssertEqual(try CommandParser.parse("select-pane -t :.+"), .selectPane(target: .next))
        XCTAssertEqual(try CommandParser.parse("select-pane -t :.-"), .selectPane(target: .previous))
        XCTAssertEqual(try CommandParser.parse("swap-pane -t !"), .swapPane(target: .last, source: nil))
    }

    /// Absolute `-t` targets parse via the full `TargetSpec` grammar into `.targeted` —
    /// names that don't exist (`bogus`) parse fine and fail loudly at *resolution*, exactly
    /// like tmux's "can't find session". Deliberate rewrite of the v1.7.1 throws-pin: the
    /// no-silent-misroute policy moved from parse time to resolve time (see
    /// `testPaneTargetEmptySpecStillThrows` for what parse still rejects).
    func testPaneTargetAbsoluteFormsParseAsTargeted() throws {
        guard case let .targeted(spec, inner) = try CommandParser.parse("swap-pane -t api:1.0") else {
            return XCTFail("expected .targeted")
        }
        XCTAssertEqual(spec.session, .byName("api"))
        XCTAssertEqual(spec.window, .byIndex(1))
        XCTAssertEqual(spec.pane, .byIndex(0))
        XCTAssertEqual(inner, .swapPane(target: .next, source: nil))

        let paneID = UUID()
        guard case let .targeted(byID, select) = try CommandParser.parse("select-pane -t %\(paneID.uuidString)") else {
            return XCTFail("expected .targeted")
        }
        XCTAssertEqual(byID.pane, .byID(paneID))
        XCTAssertEqual(select, .selectPane(target: .next))

        // A lone `{top}` is level-ambiguous at parse (window vs pane) — it rides
        // `bareToken` and resolves at the command's natural level.
        guard case let .targeted(geometry, _) = try CommandParser.parse("select-pane -t {top}") else {
            return XCTFail("expected .targeted")
        }
        XCTAssertEqual(geometry.bareToken, "{top}")

        // A lone unknown name is a session/level-ambiguous ref — parses, resolves to nothing.
        guard case .targeted = try CommandParser.parse("select-pane -t bogus") else {
            return XCTFail("expected .targeted")
        }
    }

    /// tmux `swap-pane -s <src>`: the source pane rides the command; without `-t`
    /// the destination is the current pane.
    func testSwapPaneSourceFlagParses() throws {
        let paneID = UUID()
        guard case let .swapPane(target, source) = try CommandParser.parse("swap-pane -s %\(paneID.uuidString)") else {
            return XCTFail("expected bare swapPane with source")
        }
        XCTAssertEqual(target, .current, "-s without -t swaps with the current pane")
        XCTAssertEqual(source?.pane, .byID(paneID))

        guard case let .targeted(spec, .swapPane(_, src2)) = try CommandParser.parse(
            "swap-pane -s %\(paneID.uuidString) -t api:1.0") else {
            return XCTFail("expected targeted swapPane with source")
        }
        XCTAssertEqual(spec.session, .byName("api"))
        XCTAssertEqual(src2?.pane, .byID(paneID))

        // `-s` with a relative `-t` keeps the relative destination.
        guard case let .swapPane(rel, src3) = try CommandParser.parse(
            "swap-pane -s %\(paneID.uuidString) -t :.-") else {
            return XCTFail("expected relative swapPane with source")
        }
        XCTAssertEqual(rel, .previous)
        XCTAssertEqual(src3?.pane, .byID(paneID))
    }

    /// Relative fast paths are untouched by the absolute-target branch.
    func testPaneTargetRelativeFormsStayRelative() throws {
        XCTAssertEqual(try CommandParser.parse("select-pane -t :.+"), .selectPane(target: .next))
        XCTAssertEqual(try CommandParser.parse("swap-pane -t !"), .swapPane(target: .last, source: nil))
        XCTAssertEqual(try CommandParser.parse("select-pane -L"), .selectPane(target: .left))
    }

    /// What parse still rejects loudly: a `-t` value that parses to nothing actionable.
    func testPaneTargetEmptySpecStillThrows() {
        XCTAssertThrowsError(try CommandParser.parse("select-pane -t :")) { error in
            guard let parseError = error as? CommandParseError,
                  case .invalidArgument = parseError else {
                return XCTFail("expected invalidArgument, got \(error)")
            }
        }
        XCTAssertThrowsError(try CommandParser.parse("swap-pane -t :."))
    }

    /// A dangling -t (flag present, value missing) is a typo, not a request for the default.
    func testPaneTargetDanglingFlagThrows() {
        XCTAssertThrowsError(try CommandParser.parse("select-pane -t"))
        XCTAssertThrowsError(try CommandParser.parse("swap-pane -t"))
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

    func testDisplayMenuIgnoresTrailingPartialTriple() throws {
        // A dangling group that isn't a full (title, key, command) triple is dropped,
        // not crashed on — the loop only consumes complete triples.
        XCTAssertEqual(
            try CommandParser.parse(#"display-menu "Item A" a kill-pane "Item B" b"#),
            .displayMenu(items: [.init(title: "Item A", key: "a", command: .killPane)])
        )
        // No positional triples at all yields an empty menu.
        XCTAssertEqual(
            try CommandParser.parse(#"display-menu -T "Menu""#),
            .displayMenu(items: [])
        )
    }

    // MARK: - Config / buffer / hook verbs (bindable forms)

    func testSetOptionParsesScopesAndJoinsValue() throws {
        XCTAssertEqual(
            try CommandParser.parse("set-option -g status-left ' #{session_name} '"),
            .setOption(scope: "global", target: nil, key: "status-left", rawValue: " #{session_name} ")
        )
        XCTAssertEqual(
            try CommandParser.parse("set -t automatic-rename off"),
            .setOption(scope: "tab", target: nil, key: "automatic-rename", rawValue: "off")
        )
        XCTAssertEqual(
            try CommandParser.parse("set-option -s -T abc history-limit 5000"),
            .setOption(scope: "session", target: "abc", key: "history-limit", rawValue: "5000")
        )
        // tmux setw = window option = Harness tab scope.
        XCTAssertEqual(
            try CommandParser.parse("setw monitor-activity on"),
            .setOption(scope: "tab", target: nil, key: "monitor-activity", rawValue: "on")
        )
        XCTAssertThrowsError(try CommandParser.parse("set-option -g status"))
    }

    func testShowVerbsParse() throws {
        XCTAssertEqual(try CommandParser.parse("show-options -g"), .showOptions(scope: "global"))
        XCTAssertEqual(try CommandParser.parse("show"), .showOptions(scope: nil))
        XCTAssertEqual(try CommandParser.parse("show-environment -g"), .showEnvironment(global: true))
        XCTAssertEqual(try CommandParser.parse("list-buffers"), .listBuffers)
        XCTAssertEqual(try CommandParser.parse("show-buffer -b scratch"), .showBuffer(name: "scratch"))
        XCTAssertEqual(try CommandParser.parse("show-hooks after-new-tab"), .showHooks(event: "after-new-tab"))
    }

    func testEnvironmentAndBufferVerbsParse() throws {
        XCTAssertEqual(
            try CommandParser.parse("setenv -g EDITOR vim"),
            .setEnvironment(global: true, key: "EDITOR", value: "vim")
        )
        XCTAssertEqual(
            try CommandParser.parse("set-environment -u EDITOR"),
            .setEnvironment(global: false, key: "EDITOR", value: nil)
        )
        XCTAssertEqual(
            try CommandParser.parse(#"set-buffer -b notes "hello world""#),
            .setBuffer(name: "notes", text: "hello world")
        )
        XCTAssertEqual(try CommandParser.parse("paste-buffer -b notes"), .pasteBuffer(name: "notes"))
        XCTAssertEqual(try CommandParser.parse("delete-buffer notes"), .deleteBuffer(name: "notes"))
        XCTAssertThrowsError(try CommandParser.parse("delete-buffer"))
    }

    func testSetHookParsesEventAndCommand() throws {
        XCTAssertEqual(
            try CommandParser.parse(#"set-hook after-new-tab "display-message hi""#),
            .setHook(event: "after-new-tab", source: "display-message hi", condition: nil)
        )
        XCTAssertThrowsError(try CommandParser.parse("set-hook after-new-tab"))
        let id = UUID()
        XCTAssertEqual(try CommandParser.parse("unbind-hook \(id.uuidString)"), .unbindHook(id: id))
        XCTAssertThrowsError(try CommandParser.parse("unbind-hook not-a-uuid"))
    }

    // MARK: - find-window + copy-mode-vi alias (P3)

    func testFindWindowParsesFlagsAndDefaults() throws {
        // No flags: match name + title (cheap snapshot fields), not content.
        XCTAssertEqual(
            try CommandParser.parse("find-window api"),
            .findWindow(pattern: "api", matchName: true, matchContent: false, matchTitle: true, target: nil)
        )
        XCTAssertEqual(
            try CommandParser.parse("find-window -C 'error 42'"),
            .findWindow(pattern: "error 42", matchName: false, matchContent: true, matchTitle: false, target: nil)
        )
        XCTAssertEqual(
            try CommandParser.parse("find-window -N -T build"),
            .findWindow(pattern: "build", matchName: true, matchContent: false, matchTitle: true, target: nil)
        )
        XCTAssertThrowsError(try CommandParser.parse("find-window"))
        // A `-t` value is the search scope (a session), captured as the target — never the pattern.
        XCTAssertEqual(
            try CommandParser.parse("find-window -t somewhere build"),
            .findWindow(pattern: "build", matchName: true, matchContent: false, matchTitle: true, target: "somewhere")
        )
    }

    /// tmux's table name for the vi copy-mode table is `copy-mode-vi`; Harness's is
    /// `copy-mode`. Both must work at every site a table name is typed.
    func testCopyModeViTableNameIsAccepted() throws {
        guard case let .bindKey(table, _, _, _) = try CommandParser.parse(
            "bind-key -T copy-mode-vi v copy-mode -X begin-selection") else {
            return XCTFail("expected bindKey")
        }
        XCTAssertEqual(table, "copy-mode")
        guard case let .unbindKey(unbindTable, _) = try CommandParser.parse(
            "unbind-key -T copy-mode-vi v") else {
            return XCTFail("expected unbindKey")
        }
        XCTAssertEqual(unbindTable, "copy-mode")
        XCTAssertEqual(try CommandParser.parse("list-keys -T copy-mode-vi"), .listKeys(table: "copy-mode"))
        XCTAssertEqual(
            try CommandParser.parse("switch-client -T copy-mode-vi"),
            .switchClientTable(table: "copy-mode")
        )
        // The emacs table keeps its own name.
        XCTAssertEqual(try CommandParser.parse("list-keys -T copy-mode-emacs"), .listKeys(table: "copy-mode-emacs"))
    }

    func testServerAdminVerbsParse() throws {
        XCTAssertEqual(try CommandParser.parse("refresh-client"), .refreshClient)
        XCTAssertEqual(try CommandParser.parse("refresh-client -S"), .refreshClient)
        XCTAssertEqual(try CommandParser.parse("respawn-window"), .respawnWindow(keepHistory: true))
        XCTAssertEqual(try CommandParser.parse("respawn-window -k"), .respawnWindow(keepHistory: false))
        XCTAssertEqual(try CommandParser.parse("show-messages"), .showMessages)
        // respawn-window takes the universal -t — and so does its alias.
        guard case let .targeted(spec, inner) = try CommandParser.parse("respawn-window -t :1") else {
            return XCTFail("expected .targeted")
        }
        XCTAssertEqual(spec.window, .byIndex(1))
        XCTAssertEqual(inner, .respawnWindow(keepHistory: true))
        guard case .targeted = try CommandParser.parse("respawnw -t :1") else {
            return XCTFail("respawnw alias must take the universal -t too")
        }
    }

    /// `--if <format>` makes bindable set-hook condition-capable like CLI bind-hook.
    func testSetHookParsesCondition() throws {
        XCTAssertEqual(
            try CommandParser.parse(##"set-hook --if "#{?pane_active,1,}" after-new-tab "display-message hi""##),
            .setHook(event: "after-new-tab", source: "display-message hi", condition: "#{?pane_active,1,}")
        )
    }

    /// Values that begin with `-` survive once the positional run starts (getopt):
    /// a quoted hook command with flags, a buffer payload, an env value. `--` ends
    /// flag parsing explicitly for a leading-dash first positional.
    func testDashPrefixedValuesAreNotSwallowed() throws {
        XCTAssertEqual(
            try CommandParser.parse(#"set-hook after-new-tab splitw -h"#),
            .setHook(event: "after-new-tab", source: "splitw -h", condition: nil),
            "unquoted trailing flags belong to the hook command"
        )
        XCTAssertEqual(
            try CommandParser.parse("set-environment PS1_SUFFIX -v"),
            .setEnvironment(global: false, key: "PS1_SUFFIX", value: "-v")
        )
        XCTAssertEqual(
            try CommandParser.parse(#"set-buffer -- "-rf""#),
            .setBuffer(name: nil, text: "-rf"),
            "-- ends flag parsing so a dash-leading payload parses"
        )
        // A bare key with no value still errors (tmux) rather than persisting "".
        XCTAssertThrowsError(try CommandParser.parse("set-environment LONESOME"))
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
