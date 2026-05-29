import XCTest
@testable import HarnessTerminalEngine

final class InputEncoderTests: XCTestCase {
    private let encoder = InputEncoder()

    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private var appCursor: TerminalModes {
        var m = TerminalModes()
        m.cursorKeysApplication = true
        return m
    }

    // MARK: Cursor keys

    func testArrowsNormalMode() {
        XCTAssertEqual(encoder.encode(.up), bytes("\u{1b}[A"))
        XCTAssertEqual(encoder.encode(.down), bytes("\u{1b}[B"))
        XCTAssertEqual(encoder.encode(.right), bytes("\u{1b}[C"))
        XCTAssertEqual(encoder.encode(.left), bytes("\u{1b}[D"))
    }

    func testArrowsApplicationMode() {
        XCTAssertEqual(encoder.encode(.up, modes: appCursor), bytes("\u{1b}OA"))
        XCTAssertEqual(encoder.encode(.left, modes: appCursor), bytes("\u{1b}OD"))
    }

    func testModifiedArrows() {
        XCTAssertEqual(encoder.encode(.up, modifiers: .shift), bytes("\u{1b}[1;2A"))
        XCTAssertEqual(encoder.encode(.up, modifiers: .control), bytes("\u{1b}[1;5A"))
        XCTAssertEqual(encoder.encode(.right, modifiers: [.shift, .option]), bytes("\u{1b}[1;4C"))
    }

    func testHomeEnd() {
        XCTAssertEqual(encoder.encode(.home), bytes("\u{1b}[H"))
        XCTAssertEqual(encoder.encode(.end), bytes("\u{1b}[F"))
        XCTAssertEqual(encoder.encode(.home, modes: appCursor), bytes("\u{1b}OH"))
    }

    // MARK: Function & tilde keys

    func testFunctionKeysF1toF4UseSS3() {
        XCTAssertEqual(encoder.encode(.f1), bytes("\u{1b}OP"))
        XCTAssertEqual(encoder.encode(.f4), bytes("\u{1b}OS"))
        XCTAssertEqual(encoder.encode(.f1, modifiers: .shift), bytes("\u{1b}[1;2P"))
    }

    func testFunctionKeysF5Plus() {
        XCTAssertEqual(encoder.encode(.f5), bytes("\u{1b}[15~"))
        XCTAssertEqual(encoder.encode(.f12), bytes("\u{1b}[24~"))
        XCTAssertEqual(encoder.encode(.f5, modifiers: .shift), bytes("\u{1b}[15;2~"))
    }

    func testTildeKeys() {
        XCTAssertEqual(encoder.encode(.pageUp), bytes("\u{1b}[5~"))
        XCTAssertEqual(encoder.encode(.pageDown), bytes("\u{1b}[6~"))
        XCTAssertEqual(encoder.encode(.insert), bytes("\u{1b}[2~"))
        XCTAssertEqual(encoder.encode(.deleteForward), bytes("\u{1b}[3~"))
    }

    // MARK: Simple keys

    func testSimpleControlKeys() {
        XCTAssertEqual(encoder.encode(.enter), [0x0D])
        XCTAssertEqual(encoder.encode(.escape), [0x1B])
        XCTAssertEqual(encoder.encode(.backspace), [0x7F])
        XCTAssertEqual(encoder.encode(.tab), [0x09])
        XCTAssertEqual(encoder.encode(.tab, modifiers: .shift), bytes("\u{1b}[Z"))
    }

    // MARK: Text

    func testPlainText() {
        XCTAssertEqual(encoder.encode(text: "a"), [0x61])
        XCTAssertEqual(encoder.encode(text: "Z"), [0x5A])
    }

    func testControlLetters() {
        XCTAssertEqual(encoder.encode(text: "c", modifiers: .control), [0x03])
        XCTAssertEqual(encoder.encode(text: "a", modifiers: .control), [0x01])
        XCTAssertEqual(encoder.encode(text: "[", modifiers: .control), [0x1B])
    }

    func testOptionPrefixesEscape() {
        XCTAssertEqual(encoder.encode(text: "a", modifiers: .option), [0x1B, 0x61])
        XCTAssertEqual(encoder.encode(text: "c", modifiers: [.control, .option]), [0x1B, 0x03])
    }

    // MARK: Paste

    func testBracketedPaste() {
        var modes = TerminalModes()
        XCTAssertEqual(encoder.encodePaste("hi", modes: modes), bytes("hi"))
        modes.bracketedPaste = true
        XCTAssertEqual(encoder.encodePaste("hi", modes: modes), bytes("\u{1b}[200~hi\u{1b}[201~"))
    }
}
