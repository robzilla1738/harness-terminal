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

    /// Shift (and chained C-/M-) on a named key must encode the xterm modifier form, matching the
    /// engine's InputEncoder — previously the modifier was silently dropped to the bare key.
    func testShiftAndModifiersOnNamedKeys() {
        XCTAssertEqual(KeyTokenParser.encode(keys: ["S-Tab"]), Data("\u{1B}[Z".utf8))      // back-tab
        XCTAssertEqual(KeyTokenParser.encode(keys: ["S-Up"]), Data("\u{1B}[1;2A".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["C-Right"]), Data("\u{1B}[1;5C".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["M-Down"]), Data("\u{1B}[1;3B".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["S-Home"]), Data("\u{1B}[1;2H".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["S-Delete"]), Data("\u{1B}[3;2~".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["S-PageUp"]), Data("\u{1B}[5;2~".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["S-F1"]), Data("\u{1B}[1;2P".utf8))     // SS3 → CSI
        XCTAssertEqual(KeyTokenParser.encode(keys: ["S-F5"]), Data("\u{1B}[15;2~".utf8))
        // Chained modifiers compose into one param: Ctrl(4)+Shift(1)+1 = 6.
        XCTAssertEqual(KeyTokenParser.encode(keys: ["C-S-Up"]), Data("\u{1B}[1;6A".utf8))
    }

    /// Regression: plain characters and unmodified named keys are untouched by the modifier work.
    func testUnmodifiedFormsUnchanged() {
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Down"]), Data("\u{1B}[B".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["F1"]), Data("\u{1B}OP".utf8))          // SS3, unmod
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Delete"]), Data("\u{1B}[3~".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["C-a"]), Data([0x01]))                  // C0 control
    }
}
