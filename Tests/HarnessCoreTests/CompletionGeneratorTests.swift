import XCTest
@testable import HarnessCore

final class CompletionGeneratorTests: XCTestCase {
    private let coreCommands = ["ping", "doctor", "completions", "list-workspaces"]

    func testEveryShellIsNonEmptyAndListsCoreCommands() {
        for shell in ShellIntegration.Shell.allCases {
            let script = CompletionGenerator.script(for: shell)
            XCTAssertFalse(script.isEmpty, "\(shell) completion is empty")
            for command in coreCommands {
                XCTAssertTrue(script.contains(command), "\(shell) completion is missing '\(command)'")
            }
        }
    }

    func testFishUsesCompleteDirectiveAndJSONFlags() {
        let fish = CompletionGenerator.script(for: .fish)
        XCTAssertTrue(fish.contains("complete -c harness-cli"))
        XCTAssertTrue(fish.contains("-l json"), "JSON-capable commands get a --json completion")
        XCTAssertTrue(fish.contains("-l pretty"))
        XCTAssertTrue(fish.contains("-a \"zsh fish bash\""), "completions arg values")
        XCTAssertTrue(fish.contains("codex claude-code cursor grok opencode pi hermes openclaw"), "install-hooks arg values")
    }

    func testZshIsACompdefWithDescriptions() {
        let zsh = CompletionGenerator.script(for: .zsh)
        XCTAssertTrue(zsh.hasPrefix("#compdef harness-cli"))
        XCTAssertTrue(zsh.contains("_describe"))
        // Summaries with apostrophes are escaped so the array stays valid.
        XCTAssertFalse(zsh.contains("session's:"), "apostrophes must be escaped, not raw")
        // Must register the function so it works when sourced from an rc (not just autoloaded
        // from $fpath) — otherwise `source <(harness-cli completions zsh)` defines but never wires
        // the completion.
        XCTAssertTrue(zsh.contains("compdef _harness_cli harness-cli"),
                      "sourced zsh completion must register via compdef")
    }

    func testBashRegistersACompletionFunction() {
        let bash = CompletionGenerator.script(for: .bash)
        XCTAssertTrue(bash.contains("complete -F _harness_cli harness-cli"))
        XCTAssertTrue(bash.contains("compgen -W"))
    }

    func testCatalogCoversDocumentedCommands() {
        // The catalog is the single source of truth; assert it covers every list/show + the new
        // commands so completions and the docs can't silently drop one.
        let names = Set(CLICommandCatalog.canonicalNames)
        let documented = [
            "doctor", "completions", "ping",
            "list-workspaces", "list-surfaces", "list-sessions", "list-windows", "list-panes",
            "list-agents", "list-clients", "daemon-stats",
            "show-options", "show-environment", "list-buffers", "list-hooks",
        ]
        for command in documented {
            XCTAssertTrue(names.contains(command), "catalog is missing '\(command)'")
        }
    }

    func testJSONCommandsMatchTheCatalogFlag() {
        // Every command flagged `json` in the catalog is exactly the set that should accept --json.
        let json = Set(CLICommandCatalog.jsonCommands.map(\.name))
        XCTAssertTrue(json.isSuperset(of: ["list-workspaces", "list-surfaces", "list-sessions",
                                           "list-windows", "list-panes", "list-clients",
                                           "daemon-stats", "show-options", "show-environment",
                                           "list-buffers", "list-hooks", "list-agents"]))
        XCTAssertFalse(json.contains("ping"), "non-list commands must not advertise --json")
    }
}
