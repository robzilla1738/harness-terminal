import XCTest
@testable import HarnessCore

/// Phase 6: the seeded-and-consultable `root` (`bind -n`) table. (The `send-keys -H` hex-encoding
/// test moved to `KeyTokenParserTests` in HarnessTerminalEngineTests when `KeyTokenParser` moved
/// next to `InputEncoder`.)
final class Phase6KeysTests: XCTestCase {
    func testRootTableSeededAndBindable() {
        var set = KeyTableSet.defaults
        // Seeded (empty) so `bind-key -T root` is a real surface, not a no-op.
        XCTAssertNotNil(set.table(.root))
        XCTAssertEqual(set.table(.root)?.bindings.count, 0)
        set.setBinding(table: .root, binding: Binding(spec: KeySpec(key: "Right", modifiers: .option), command: .nextWindow))
        XCTAssertEqual(set.table(.root)?.lookup(KeySpec(key: "Right", modifiers: .option))?.command, .nextWindow)
    }
}
