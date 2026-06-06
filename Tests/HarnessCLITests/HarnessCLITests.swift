import XCTest
@testable import HarnessCLI
import HarnessCore

/// Coverage for the CLI's pure argument-parsing helpers. `harness-cli` previously had no test
/// target at all, so a refactor could silently break flag parsing. `flagValue` is the shared
/// extractor behind ~40 subcommands; its "flag present but no value follows" case (returns nil,
/// which callers treat as "not supplied") is the one the audit flagged as untested.
final class HarnessCLITests: XCTestCase {
    func testFlagValueReturnsTheFollowingToken() {
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "abc"], flag: "--tab"), "abc")
        XCTAssertEqual(HarnessCLI.flagValue(["--cwd", "~", "--tab", "id"], flag: "--tab"), "id")
    }

    func testFlagValueIsNilWhenFlagHasNoValue() {
        // Flag is the final token, so no value follows. Regression guard: this must stay nil (not
        // crash or read past the end), and callers fall back to their usage error.
        XCTAssertNil(HarnessCLI.flagValue(["close-tab", "--tab"], flag: "--tab"))
    }

    func testFlagValueIsNilWhenFlagAbsent() {
        XCTAssertNil(HarnessCLI.flagValue(["--workspace", "Default"], flag: "--tab"))
        XCTAssertNil(HarnessCLI.flagValue([], flag: "--tab"))
    }

    func testFlagValueTakesFirstOccurrence() {
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "first", "--tab", "second"], flag: "--tab"), "first")
    }

    func testFlagValueTakesNextTokenVerbatimEvenIfFlagLike() {
        // Documents current behavior: the token immediately after the flag is taken verbatim, even
        // if it itself looks like a flag — callers validate the value, not flagValue.
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "--oops"], flag: "--tab"), "--oops")
    }

    /// Drift guard: `CLICommandCatalog` is the single source of truth for shell completions, so it
    /// must list every top-level verb the `HarnessCLI.main` dispatch `switch` accepts — otherwise a
    /// new subcommand silently never completes. This is the dispatch switch's canonical verb list
    /// (the first label of each `case`, excluding pure aliases like `--version`/`setw`). Whenever a
    /// `case` is added to the dispatch in `HarnessCLI.swift`, add it here too; the assertion below
    /// then fails until the catalog grows the matching entry.
    func testCatalogCoversEveryDispatchCommand() {
        let dispatchVerbs: Set<String> = [
            "color-check", "theme-preview", "remote", "daemon", "version",
            "list-workspaces", "list-surfaces", "list-sessions", "list-agents", "doctor",
            "completions", "list-windows", "list-panes", "has-session", "list-commands",
            "get-snapshot", "new-workspace", "new-session", "new-tab", "new-split",
            "select-workspace", "select-tab", "select-session", "close-tab", "close-session",
            "promote-session", "demote-session", "send", "notify", "install", "ping",
            "send-keys", "capture-pane", "pipe-pane", "wait-for", "link-window", "unlink-window",
            "control-mode", "kill-pane", "swap-pane", "resize-pane", "zoom-pane", "copy-mode",
            "rename-tab", "rename-session", "rename-workspace", "detect-agent", "install-hooks",
            "install-shell-integration", "attach", "attach-window", "record", "replay",
            "daemon-stats", "list-clients", "detach-client", "bind-key", "unbind-key", "list-keys",
            "set-buffer", "list-buffers", "show-buffer", "delete-buffer", "paste-buffer",
            "save-buffer", "load-buffer", "select-layout", "next-layout", "previous-layout",
            "rotate-window", "break-pane", "join-pane", "move-pane", "renumber-windows",
            "respawn-pane", "select-pane", "set-option", "show-options", "set-environment",
            "show-environment", "bind-hook", "unbind-hook", "list-hooks", "display-message",
        ]
        let catalog = Set(CLICommandCatalog.canonicalNames)
        let missing = dispatchVerbs.subtracting(catalog).sorted()
        XCTAssertTrue(missing.isEmpty,
                      "CLICommandCatalog is missing dispatch verbs (shell completions will drop them): \(missing)")
    }
}
