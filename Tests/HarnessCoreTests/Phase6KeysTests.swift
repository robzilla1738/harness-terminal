import XCTest
@testable import HarnessCore

/// Phase 6: `send-keys -H` hex encoding and the seeded-and-consultable `root` (`bind -n`) table.
final class Phase6KeysTests: XCTestCase {
    func testHexBytesEncoding() {
        XCTAssertEqual(KeyTokenParser.hexBytes(["1b", "5b", "41"]), Data([0x1b, 0x5b, 0x41]))
        XCTAssertEqual(KeyTokenParser.hexBytes(["0x0d"]), Data([0x0d]))
        XCTAssertEqual(KeyTokenParser.hexBytes(["zz", "41"]), Data([0x41])) // non-hex skipped
        XCTAssertEqual(KeyTokenParser.hexBytes([]), Data())
    }

    func testRootTableSeededAndBindable() {
        var set = KeyTableSet.defaults
        // Seeded (empty) so `bind-key -T root` is a real surface, not a no-op.
        XCTAssertNotNil(set.table(.root))
        XCTAssertEqual(set.table(.root)?.bindings.count, 0)
        set.setBinding(table: .root, binding: Binding(spec: KeySpec(key: "Right", modifiers: .option), command: .nextWindow))
        XCTAssertEqual(set.table(.root)?.lookup(KeySpec(key: "Right", modifiers: .option))?.command, .nextWindow)
    }
}
