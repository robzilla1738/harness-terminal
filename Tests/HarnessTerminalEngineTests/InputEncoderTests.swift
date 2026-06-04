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

    // MARK: macOS line-editing keys

    func testBackspaceModifiers() {
        XCTAssertEqual(encoder.encode(.backspace), [0x7F])                      // plain → DEL
        XCTAssertEqual(encoder.encode(.backspace, modifiers: .option), [0x1B, 0x7F]) // word delete
        XCTAssertEqual(encoder.encode(.backspace, modifiers: .control), [0x08]) // ^H
    }

    func testOptionWordMotion() {
        // Option-only Left/Right → readline word motions; app cursor mode irrelevant here.
        XCTAssertEqual(encoder.encode(.left, modifiers: .option), bytes("\u{1b}b"))
        XCTAssertEqual(encoder.encode(.right, modifiers: .option), bytes("\u{1b}f"))
        XCTAssertEqual(encoder.encode(.deleteForward, modifiers: .option), bytes("\u{1b}d"))
    }

    func testOtherModifierArrowsStayCSI() {
        // Anything beyond Option-only keeps the xterm CSI form (TUIs depend on it).
        XCTAssertEqual(encoder.encode(.left, modifiers: [.option, .shift]), bytes("\u{1b}[1;4D"))
        XCTAssertEqual(encoder.encode(.right, modifiers: .control), bytes("\u{1b}[1;5C"))
        XCTAssertEqual(encoder.encode(.deleteForward, modifiers: .shift), bytes("\u{1b}[3;2~"))
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

    // MARK: Mouse

    func testMouseReturnsEmptyWhenTrackingOff() {
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0, modes: TerminalModes()), [])
    }

    func testMouseSGRPressAndRelease() {
        var modes = TerminalModes()
        modes.mouseClick = true
        modes.mouseSGR = true
        // 0-based (4,9) -> 1-based (5,10); left = 0; press = M, release = m.
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 4, row: 9, modes: modes),
                       bytes("\u{1b}[<0;5;10M"))
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .release, column: 4, row: 9, modes: modes),
                       bytes("\u{1b}[<0;5;10m"))
    }

    func testMouseSGRDragModifiersAndWheel() {
        var modes = TerminalModes()
        modes.mouseAny = true
        modes.mouseSGR = true
        // Drag adds 32, control adds 16 -> 0 + 16 + 32 = 48.
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .drag, column: 0, row: 0, modifiers: .control, modes: modes),
                       bytes("\u{1b}[<48;1;1M"))
        // Wheel up = 64.
        XCTAssertEqual(encoder.encodeMouse(button: .wheelUp, kind: .press, column: 2, row: 3, modes: modes),
                       bytes("\u{1b}[<64;3;4M"))
    }

    func testMouseSGRHorizontalWheel() {
        var modes = TerminalModes()
        modes.mouseAny = true
        modes.mouseSGR = true
        // Horizontal wheel: left = 66, right = 67 (xterm wheel button codes).
        XCTAssertEqual(encoder.encodeMouse(button: .wheelLeft, kind: .press, column: 2, row: 3, modes: modes),
                       bytes("\u{1b}[<66;3;4M"))
        XCTAssertEqual(encoder.encodeMouse(button: .wheelRight, kind: .press, column: 2, row: 3, modes: modes),
                       bytes("\u{1b}[<67;3;4M"))
    }

    func testMouseLegacyX10() {
        var modes = TerminalModes()
        modes.mouseClick = true // no SGR -> legacy byte form
        // ESC [ M, then Cb=0+32, Cx=(0+1)+32, Cy=(0+1)+32.
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0, modes: modes),
                       [0x1B, 0x5B, 0x4D, 32, 33, 33])
    }
}
