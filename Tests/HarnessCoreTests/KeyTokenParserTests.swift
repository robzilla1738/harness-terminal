import XCTest
@testable import HarnessCore

final class KeyTokenParserTests: XCTestCase {
    func testEncodesCommonTokens() {
        XCTAssertEqual(KeyTokenParser.encode(keys: ["C-c"]), Data([0x03]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Enter"]), Data([0x0D]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Tab"]), Data([0x09]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Escape"]), Data([0x1B]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Up"]), Data([0x1B, 0x5B, 0x41]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["M-x"]), Data([0x1B, 0x78]))
    }
}
