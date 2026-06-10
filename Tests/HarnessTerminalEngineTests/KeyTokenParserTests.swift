import XCTest
@testable import HarnessTerminalEngine

final class KeyTokenParserTests: XCTestCase {
    func testHexBytesEncoding() {
        XCTAssertEqual(KeyTokenParser.hexBytes(["1b", "5b", "41"]), Data([0x1b, 0x5b, 0x41]))
        XCTAssertEqual(KeyTokenParser.hexBytes(["0x0d"]), Data([0x0d]))
        XCTAssertEqual(KeyTokenParser.hexBytes(["zz", "41"]), Data([0x41])) // non-hex skipped
        XCTAssertEqual(KeyTokenParser.hexBytes([]), Data())
    }

    func testEncodesCommonTokens() {
        XCTAssertEqual(KeyTokenParser.encode(keys: ["C-c"]), Data([0x03]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Enter"]), Data([0x0D]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Tab"]), Data([0x09]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Escape"]), Data([0x1B]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Up"]), Data([0x1B, 0x5B, 0x41]))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["M-x"]), Data([0x1B, 0x78]))
    }

    /// Shift (and chained C-/M-) on a named key encodes the xterm modifier form — now produced by
    /// the engine's `InputEncoder` (one encoder), so `send-keys S-Up` is byte-identical to a
    /// physical Shift+Up. These all match the values the old hand-maintained table produced.
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

    /// Plain characters, `Space`, and unmodified named keys.
    func testUnmodifiedFormsUnchanged() {
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Down"]), Data("\u{1B}[B".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["F1"]), Data("\u{1B}OP".utf8))          // SS3, unmod
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Delete"]), Data("\u{1B}[3~".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["C-a"]), Data([0x01]))                  // C0 control
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Space"]), Data([0x20]))               // literal space
        XCTAssertEqual(KeyTokenParser.encode(keys: ["hello"]), Data("hello".utf8))         // literal text
    }

    /// Convergence onto physical-keypress bytes: now that the one encoder is used, Option-modified
    /// editing keys emit the macOS readline word motions a real Alt+key sends (the old hand-rolled
    /// table emitted the CSI modifier form instead). Matching physical input is the point of unifying.
    func testOptionModifiedKeysMatchPhysicalKeypress() {
        let enc = InputEncoder()
        XCTAssertEqual(KeyTokenParser.encode(keys: ["M-Left"]), Data(enc.encode(.left, modifiers: .option)))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["M-Right"]), Data(enc.encode(.right, modifiers: .option)))
        // Specifically the readline word motions (ESC b / ESC f).
        XCTAssertEqual(KeyTokenParser.encode(keys: ["M-Left"]), Data("\u{1B}b".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["M-Right"]), Data("\u{1B}f".utf8))
    }

    /// The `modes:` seam: when a caller supplies the target surface's DECCKM (application-cursor)
    /// mode, the cursor keys encode in SS3 form — the same bytes a physical arrow press produces in
    /// that mode. (The daemon's `send-keys` is mode-blind by design and passes default modes, so its
    /// output is unchanged; this proves the unified path is mode-correct when modes are known.)
    func testModeAwareEncodingHonorsApplicationCursorKeys() {
        var app = TerminalModes()
        app.cursorKeysApplication = true
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Up"], modes: app), Data("\u{1B}OA".utf8))
        XCTAssertEqual(KeyTokenParser.encode(keys: ["Up"]), Data("\u{1B}[A".utf8)) // default (normal) mode
    }
}
