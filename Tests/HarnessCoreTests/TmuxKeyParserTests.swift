import XCTest
@testable import HarnessCore

final class TmuxKeyParserTests: XCTestCase {
    func testEncodesCommonTmuxTokens() {
        XCTAssertEqual(TmuxKeyParser.encode(keys: ["C-c"]), Data([0x03]))
        XCTAssertEqual(TmuxKeyParser.encode(keys: ["Enter"]), Data([0x0D]))
        XCTAssertEqual(TmuxKeyParser.encode(keys: ["Tab"]), Data([0x09]))
        XCTAssertEqual(TmuxKeyParser.encode(keys: ["Escape"]), Data([0x1B]))
        XCTAssertEqual(TmuxKeyParser.encode(keys: ["Up"]), Data([0x1B, 0x5B, 0x41]))
        XCTAssertEqual(TmuxKeyParser.encode(keys: ["M-x"]), Data([0x1B, 0x78]))
    }
}
