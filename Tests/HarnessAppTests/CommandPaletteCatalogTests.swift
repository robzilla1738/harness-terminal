import Foundation
import XCTest
@testable import HarnessApp
import HarnessCore

/// The palette's command catalog is derived, never hand-maintained: every bindable verb is
/// reachable (directly or via the pre-filled `:` prompt), and the curated-exclusion set can't
/// drift from the real vocabulary.
final class CommandPaletteCatalogTests: XCTestCase {
    func testEveryKnownVerbIsCoveredExactlyOnce() {
        let entries = CommandPaletteCatalog.entries()
        let verbs = Set(entries.map(\.verb))
        XCTAssertEqual(entries.count, verbs.count, "no duplicate catalog rows")
        let expected = Set(CommandParser.knownVerbs).subtracting(CommandPaletteCatalog.curatedVerbs)
        XCTAssertEqual(verbs, expected, "catalog = knownVerbs minus curated, nothing else")
    }

    func testCuratedVerbsActuallyExistInTheVocabulary() {
        // Aliases like new-tab/rename-tab are part of the parser surface even when not listed
        // in knownVerbs; everything else in the exclusion set must be a real verb, or the set
        // has drifted (a typo would silently re-add a duplicate row).
        let known = Set(CommandParser.knownVerbs)
        for verb in CommandPaletteCatalog.curatedVerbs where !["new-tab", "rename-tab"].contains(verb) {
            XCTAssertTrue(
                known.contains(verb) || (try? CommandParser.parse(verb)) != nil,
                "curated verb \(verb) is not in the vocabulary"
            )
        }
    }

    func testArglessVerbsRunDirectAndArgVerbsPrompt() throws {
        let entries = CommandPaletteCatalog.entries()
        func entry(_ verb: String) throws -> CommandPaletteCatalog.Entry {
            try XCTUnwrap(entries.first { $0.verb == verb }, "missing \(verb)")
        }
        // Argument-less verbs execute directly with their parsed command.
        XCTAssertEqual(try entry("clear-history").kind, .direct(.clearHistory))
        XCTAssertEqual(try entry("jump-previous-prompt").kind, .direct(.jumpToPreviousPrompt))
        // Argument-requiring verbs fall back to the pre-filled command prompt — both the
        // ones that fail to parse bare and the ones that parse to empty-arg no-ops.
        XCTAssertEqual(try entry("bind-key").kind, .prompt)
        XCTAssertEqual(try entry("select-layout").kind, .prompt)
        XCTAssertEqual(try entry("send-keys").kind, .prompt)
        XCTAssertEqual(try entry("display-message").kind, .prompt)
    }

    func testBindingDisplayMapFormatsPrefixAndRootBindings() {
        let prefix = KeyTable(id: .prefix, bindings: [
            Binding(spec: KeySpec(key: "x"), command: .killPane, note: nil),
        ])
        let root = KeyTable(id: .root, bindings: [
            Binding(spec: KeySpec(key: "h", modifiers: .control), command: .clearHistory, note: nil),
        ])
        let map = CommandPaletteCatalog.bindingDisplayMap(tables: KeyTableSet(tables: [prefix, root]))
        XCTAssertEqual(map[Command.killPane.shortDescription], "Prefix x")
        XCTAssertEqual(map[Command.clearHistory.shortDescription], KeySpec(key: "h", modifiers: .control).description)
    }
}
