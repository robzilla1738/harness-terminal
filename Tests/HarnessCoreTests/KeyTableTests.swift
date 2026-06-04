import XCTest
@testable import HarnessCore

final class KeyTableTests: XCTestCase {
    func testKeySpecParsesCommonForms() throws {
        XCTAssertEqual(KeySpec.parse("c"), KeySpec(key: "c"))
        XCTAssertEqual(KeySpec.parse("C-a"), KeySpec(key: "a", modifiers: .control))
        XCTAssertEqual(KeySpec.parse("M-1"), KeySpec(key: "1", modifiers: .option))
        XCTAssertEqual(KeySpec.parse("S-Tab"), KeySpec(key: "Tab", modifiers: .shift))
        XCTAssertEqual(KeySpec.parse("C-M-x"), KeySpec(key: "x", modifiers: [.control, .option]))
        XCTAssertEqual(KeySpec.parse("-"), KeySpec(key: "-"))
    }

    func testKeySpecRoundTripsThroughString() throws {
        let specs = [
            KeySpec(key: "a"),
            KeySpec(key: "Up", modifiers: .shift),
            KeySpec(key: "[", modifiers: .control),
            KeySpec(key: "F5", modifiers: [.command, .option]),
        ]
        for spec in specs {
            let encoded = spec.description
            XCTAssertEqual(KeySpec.parse(encoded), spec, "round-trip failed for \(encoded)")
        }
    }

    func testKeySpecInvalidStringReturnsNil() {
        XCTAssertNil(KeySpec.parse("Q-x"))     // unknown modifier
        XCTAssertNil(KeySpec.parse("C-"))      // missing key
    }

    func testKeyTableLookupSetAndRemove() {
        var table = KeyTable(id: .prefix)
        let spec = KeySpec(key: "c")
        table.set(Binding(spec: spec, command: .newWindow))
        XCTAssertEqual(table.lookup(spec)?.command, .newWindow)
        table.set(Binding(spec: spec, command: .killPane)) // replace
        XCTAssertEqual(table.lookup(spec)?.command, .killPane)
        table.remove(spec: spec)
        XCTAssertNil(table.lookup(spec))
    }

    func testDefaultsContainExpectedPrefixBindings() {
        let defaults = KeyTableSet.defaults
        let prefix = defaults.table(.prefix)
        XCTAssertEqual(prefix?.lookup(KeySpec(key: "c"))?.command, .newWindow)
        XCTAssertEqual(prefix?.lookup(KeySpec(key: "%"))?.command, .splitWindow(direction: .vertical))
        XCTAssertEqual(prefix?.lookup(KeySpec(key: "["))?.command, .copyMode)
        XCTAssertEqual(prefix?.lookup(KeySpec(key: "d"))?.command, .detachClient)
    }

    func testCopyModePromptJumpBindings() {
        let defaults = KeyTableSet.defaults
        // vi copy-mode: bare [ / ] jump between OSC 133 prompts (free keys — no prior binding).
        let vi = defaults.table(.copyMode)
        XCTAssertEqual(vi?.lookup(KeySpec(key: "["))?.command, .copyModeCommand(.previousPrompt))
        XCTAssertEqual(vi?.lookup(KeySpec(key: "]"))?.command, .copyModeCommand(.nextPrompt))
        // emacs copy-mode: M-[ / M-] (the bare brackets stay free there).
        let emacs = defaults.table(.copyModeEmacs)
        XCTAssertEqual(emacs?.lookup(KeySpec(key: "[", modifiers: .option))?.command, .copyModeCommand(.previousPrompt))
        XCTAssertEqual(emacs?.lookup(KeySpec(key: "]", modifiers: .option))?.command, .copyModeCommand(.nextPrompt))
        XCTAssertNil(emacs?.lookup(KeySpec(key: "[")), "bare [ is unbound in emacs copy-mode")
    }

    func testCopyModeArrowKeysMirrorMotions() {
        // Arrows must move the cursor in both copy-mode tables (tmux parity) — unbound keys are
        // swallowed in copy mode, which used to make arrows dead there.
        for table in [KeyTableSet.defaults.table(.copyMode),
                      KeyTableSet.defaults.table(.copyModeEmacs)].compactMap({ $0 }) {
            XCTAssertEqual(table.lookup(KeySpec(key: "Up"))?.command, .copyModeCommand(.cursorUp), table.id.rawValue)
            XCTAssertEqual(table.lookup(KeySpec(key: "Down"))?.command, .copyModeCommand(.cursorDown), table.id.rawValue)
            XCTAssertEqual(table.lookup(KeySpec(key: "Left"))?.command, .copyModeCommand(.cursorLeft), table.id.rawValue)
            XCTAssertEqual(table.lookup(KeySpec(key: "Right"))?.command, .copyModeCommand(.cursorRight), table.id.rawValue)
        }
    }

    func testNoDuplicateKeySpecsInDefaultTables() {
        // Each default table must map every KeySpec at most once — guards against a new binding
        // silently shadowing an existing one (e.g. the copy-mode prompt-jump keys).
        for table in [KeyTableSet.defaults.table(.prefix),
                      KeyTableSet.defaults.table(.copyMode),
                      KeyTableSet.defaults.table(.copyModeEmacs)].compactMap({ $0 }) {
            let specs = table.bindings.map(\.spec)
            XCTAssertEqual(Set(specs).count, specs.count, "duplicate KeySpec in table \(table.id.rawValue)")
        }
    }

    func testKeyTableSetJSONRoundTripPreservesBindings() throws {
        var set = KeyTableSet.defaults
        set.setBinding(
            table: .prefix,
            binding: Binding(spec: KeySpec(key: "S", modifiers: .shift), command: .killWindow, note: "custom")
        )
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(KeyTableSet.self, from: data)
        XCTAssertEqual(decoded.table(.prefix)?.lookup(KeySpec(key: "S", modifiers: .shift))?.command, .killWindow)
    }
}
