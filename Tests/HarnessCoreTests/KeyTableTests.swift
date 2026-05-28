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
