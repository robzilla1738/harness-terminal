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

    /// A hostile clipboard payload that embeds the bracketed-paste END marker must not be able to
    /// break out: the inner `ESC[201~` is stripped so everything stays inside the one paste, and
    /// the trailing `; rm -rf /` never reaches the program as typed input.
    func testBracketedPasteStripsEmbeddedEndMarker() {
        var modes = TerminalModes()
        modes.bracketedPaste = true
        let hostile = "a\u{1b}[201~; rm -rf /\n"
        let out = encoder.encodePaste(hostile, modes: modes)
        // Exactly one START and one END marker remain — the wrappers we added, none from the body —
        // so the trailing `; rm -rf /` stays inside the paste rather than running as typed input.
        XCTAssertEqual(out, bytes("\u{1b}[200~a; rm -rf /\n\u{1b}[201~"))
    }

    /// Multiple embedded markers (and a marker spanning would-be boundaries) are all removed.
    func testBracketedPasteStripsRepeatedEndMarkers() {
        var modes = TerminalModes()
        modes.bracketedPaste = true
        let hostile = "\u{1b}[201~one\u{1b}[201~two\u{1b}[201~"
        let out = encoder.encodePaste(hostile, modes: modes)
        XCTAssertEqual(out, bytes("\u{1b}[200~onetwo\u{1b}[201~"))
    }

    /// Stripping operates on raw bytes, so it must never corrupt a multi-byte UTF-8 scalar whose
    /// continuation bytes happen to overlap marker byte values.
    func testBracketedPastePreservesMultibyteContent() {
        var modes = TerminalModes()
        modes.bracketedPaste = true
        // U+06DB ("ۛ") encodes as 0xDB 0x9B; the leading scalar must survive untouched.
        let text = "café — ۛ test"
        XCTAssertEqual(encoder.encodePaste(text, modes: modes),
                       bytes("\u{1b}[200~") + bytes(text) + bytes("\u{1b}[201~"))
    }

    /// When bracketed paste is off there is no paste boundary to defend, so the body passes through
    /// verbatim (the GUI's separate paste-protection prompt covers the unbracketed case).
    func testUnbracketedPasteIsVerbatim() {
        let modes = TerminalModes()
        let text = "a\u{1b}[201~b"
        XCTAssertEqual(encoder.encodePaste(text, modes: modes), bytes(text))
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

    // MARK: Numeric keypad (F30: DECKPAM/DECKPNM)

    private var appKeypad: TerminalModes {
        var m = TerminalModes()
        m.keypadApplication = true
        return m
    }

    /// Numeric (default) mode: keypad keys emit the same plain bytes the text path used to
    /// produce — byte-identical until a program enables application keypad.
    func testKeypadNumericModeEmitsPlainBytes() {
        XCTAssertEqual(encoder.encode(.keypad0), bytes("0"))
        XCTAssertEqual(encoder.encode(.keypad9), bytes("9"))
        XCTAssertEqual(encoder.encode(.keypadDecimal), bytes("."))
        XCTAssertEqual(encoder.encode(.keypadPlus), bytes("+"))
        XCTAssertEqual(encoder.encode(.keypadMinus), bytes("-"))
        XCTAssertEqual(encoder.encode(.keypadMultiply), bytes("*"))
        XCTAssertEqual(encoder.encode(.keypadDivide), bytes("/"))
        XCTAssertEqual(encoder.encode(.keypadEquals), bytes("="))
        XCTAssertEqual(encoder.encode(.keypadEnter), [0x0D])
    }

    /// DECKPAM: the xterm SS3 application forms (`SS3 p`…`SS3 y`, operators per the VT220 table).
    func testKeypadApplicationModeEmitsSS3() {
        XCTAssertEqual(encoder.encode(.keypad0, modes: appKeypad), bytes("\u{1b}Op"))
        XCTAssertEqual(encoder.encode(.keypad1, modes: appKeypad), bytes("\u{1b}Oq"))
        XCTAssertEqual(encoder.encode(.keypad5, modes: appKeypad), bytes("\u{1b}Ou"))
        XCTAssertEqual(encoder.encode(.keypad9, modes: appKeypad), bytes("\u{1b}Oy"))
        XCTAssertEqual(encoder.encode(.keypadDecimal, modes: appKeypad), bytes("\u{1b}On"))
        XCTAssertEqual(encoder.encode(.keypadDivide, modes: appKeypad), bytes("\u{1b}Oo"))
        XCTAssertEqual(encoder.encode(.keypadMultiply, modes: appKeypad), bytes("\u{1b}Oj"))
        XCTAssertEqual(encoder.encode(.keypadMinus, modes: appKeypad), bytes("\u{1b}Om"))
        XCTAssertEqual(encoder.encode(.keypadPlus, modes: appKeypad), bytes("\u{1b}Ok"))
        XCTAssertEqual(encoder.encode(.keypadEnter, modes: appKeypad), bytes("\u{1b}OM"))
        XCTAssertEqual(encoder.encode(.keypadEquals, modes: appKeypad), bytes("\u{1b}OX"))
    }

    /// The emulator end of F30: `ESC =` / `ESC >` flip the flag the encoder consults, and
    /// DECSTR resets it.
    func testDECKPAMTogglesKeypadApplicationFlag() {
        let term = TerminalEmulator(cols: 10, rows: 2)
        XCTAssertFalse(term.modes.keypadApplication)
        term.feed("\u{1b}=")
        XCTAssertTrue(term.modes.keypadApplication)
        term.feed("\u{1b}>")
        XCTAssertFalse(term.modes.keypadApplication)
        term.feed("\u{1b}=\u{1b}[!p") // DECSTR resets keyboard modes
        XCTAssertFalse(term.modes.keypadApplication)
    }

    /// Kitty active: keypad keys report their functional codepoints (`CSI <cp> u`).
    func testKeypadUnderKittyReportsFunctionalCodepoints() {
        var m = TerminalModes()
        m.kittyKeyboardStack = [0b1]
        XCTAssertEqual(encoder.encode(.keypad0, modes: m), bytes("\u{1b}[57399u"))
        XCTAssertEqual(encoder.encode(.keypadEnter, modes: m), bytes("\u{1b}[57414u"))
    }
}
