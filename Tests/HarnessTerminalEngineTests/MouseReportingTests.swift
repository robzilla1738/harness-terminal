import XCTest
@testable import HarnessTerminalEngine

/// Mouse-reporting encode path: tests that `InputEncoder.encodeMouse` produces the
/// correct byte sequences for every mode/button/modifier combination, and that the
/// emulator correctly gates the modes via DECSET / DECRST.
///
/// The implementation stores three separate "tracking tier" flags in `TerminalModes`:
///   - `mouseClick`  → mode 1000 (press + release only)
///   - `mouseDrag`   → mode 1002 (press, release, drag)
///   - `mouseAny`    → mode 1003 (press, release, drag, plain motion)
/// and an orthogonal encoding flag `mouseSGR` → mode 1006 (unbounded coordinates).
/// `mouseTrackingEnabled` is the OR of the three tier flags.
///
/// `encodeMouse` takes 0-based `column`/`row` and adds 1 internally to produce
/// the 1-based coordinates the wire protocol requires.
///
/// SGR (mode 1006): press → `ESC [ < cb ; col ; row M`, release → `… m`.
/// Legacy X10: `ESC [ M` + three raw bytes (each offset by 32); coordinates clamped
///             to 223 (the max that fits in one byte without wrapping past 255).
///
/// SGR-pixel (mode 1016): the 1006 framing with pixel coordinates supplied by the host;
/// takes precedence over 1006 when both are set. Legacy modes 1005 and 1015 remain
/// unimplemented (see `testUnsupportedModeIsNoOp`).
final class MouseReportingTests: XCTestCase {

    private let encoder = InputEncoder()

    // MARK: - Convenience helpers

    /// Bytes from a String literal (UTF-8).
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Build a TerminalModes value with both a tracking tier and optional SGR.
    private func modes(click: Bool = false, drag: Bool = false, any: Bool = false, sgr: Bool = false) -> TerminalModes {
        var m = TerminalModes()
        m.mouseClick = click
        m.mouseDrag  = drag
        m.mouseAny   = any
        m.mouseSGR   = sgr
        return m
    }

    // MARK: - Mode gating: no mode → empty result

    /// `encodeMouse` must return empty when `mouseTrackingEnabled` is false, regardless
    /// of which button/kind/coordinates are supplied.  This is the most important gate —
    /// hosts rely on it to avoid reporting mouse events when the program never asked.
    func testNoModeReturnsEmpty() {
        let off = TerminalModes()  // all false by default
        XCTAssertEqual(encoder.encodeMouse(button: .left,    kind: .press,   column: 0, row: 0, modes: off), [],
                       "left press with no mode must be empty")
        XCTAssertEqual(encoder.encodeMouse(button: .right,   kind: .release, column: 5, row: 3, modes: off), [],
                       "right release with no mode must be empty")
        XCTAssertEqual(encoder.encodeMouse(button: .middle,  kind: .drag,    column: 9, row: 9, modes: off), [],
                       "middle drag with no mode must be empty")
        XCTAssertEqual(encoder.encodeMouse(button: .wheelUp, kind: .press,   column: 0, row: 0, modes: off), [],
                       "wheelUp with no mode must be empty")
    }

    // MARK: - Mode gating via the emulator (DECSET sequences)

    /// Feeding `ESC [ ? 1000 h` must flip `modes.mouseClick`; the subsequent encode must
    /// produce a non-empty sequence.  This mirrors how `InputEncoderTests.swift` tests
    /// bracketed paste — set the mode via feed, then encode.
    func testDECSETEnablesMode1000() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        XCTAssertFalse(term.modes.mouseClick, "mouseClick starts false")
        term.feed("\u{1b}[?1000h")
        XCTAssertTrue(term.modes.mouseClick, "ESC[?1000h must set mouseClick")
        // Encoding with the emulator's live modes must now produce bytes.
        let result = encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0, modes: term.modes)
        XCTAssertFalse(result.isEmpty, "mode 1000 active → encode must produce bytes")
    }

    /// `ESC [ ? 1000 l` resets mode 1000.
    func testDECRSTDisablesMode1000() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1000h")
        XCTAssertTrue(term.modes.mouseClick)
        term.feed("\u{1b}[?1000l")
        XCTAssertFalse(term.modes.mouseClick, "ESC[?1000l must clear mouseClick")
    }

    func testDECSETEnablesMode1002() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1002h")
        XCTAssertTrue(term.modes.mouseDrag, "ESC[?1002h must set mouseDrag")
        let result = encoder.encodeMouse(button: .left, kind: .drag, column: 0, row: 0, modes: term.modes)
        XCTAssertFalse(result.isEmpty)
    }

    func testDECSETEnablesMode1003() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1003h")
        XCTAssertTrue(term.modes.mouseAny, "ESC[?1003h must set mouseAny")
    }

    func testDECSETEnablesMode1006() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1006h")
        XCTAssertTrue(term.modes.mouseSGR, "ESC[?1006h must set mouseSGR")
        // mode 1006 alone does NOT enable tracking: mouseTrackingEnabled requires a tier flag.
        XCTAssertFalse(term.modes.mouseTrackingEnabled,
                       "mouseSGR alone must not set mouseTrackingEnabled — a tier flag (1000/1002/1003) is still required")
    }

    // MARK: - SGR (mode 1006) encoding

    /// Left press at 0-based (col=4, row=9): wire is 1-based → `ESC [ < 0 ; 5 ; 10 M`.
    /// This is the reference case from InputEncoderTests — replicated here with a comment
    /// explaining the design rather than treating InputEncoderTests as a no-op gap.
    func testSGRLeftPress() {
        let m = modes(click: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 4, row: 9, modes: m),
                       bytes("\u{1b}[<0;5;10M"),
                       "left=0, 0-based(4,9) → 1-based(5,10), press→M")
    }

    /// Left release shares the same coordinate path but uses trailing `m`.
    func testSGRLeftRelease() {
        let m = modes(click: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .release, column: 4, row: 9, modes: m),
                       bytes("\u{1b}[<0;5;10m"),
                       "release → lowercase m")
    }

    /// Right button code is 2.
    func testSGRRightButton() {
        let m = modes(click: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .right, kind: .press, column: 0, row: 0, modes: m),
                       bytes("\u{1b}[<2;1;1M"))
    }

    /// Middle button code is 1.
    func testSGRMiddleButton() {
        let m = modes(click: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .middle, kind: .press, column: 0, row: 0, modes: m),
                       bytes("\u{1b}[<1;1;1M"))
    }

    /// Wheel-up raw value is 64 → code 64, no trailing modifier bits here.
    func testSGRWheelUp() {
        let m = modes(any: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .wheelUp, kind: .press, column: 2, row: 3, modes: m),
                       bytes("\u{1b}[<64;3;4M"))
    }

    /// Wheel-down raw value is 65.
    func testSGRWheelDown() {
        let m = modes(any: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .wheelDown, kind: .press, column: 2, row: 3, modes: m),
                       bytes("\u{1b}[<65;3;4M"))
    }

    /// Horizontal wheel left = 66, right = 67 (xterm extension).
    func testSGRHorizontalWheel() {
        let m = modes(any: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .wheelLeft,  kind: .press, column: 2, row: 3, modes: m),
                       bytes("\u{1b}[<66;3;4M"))
        XCTAssertEqual(encoder.encodeMouse(button: .wheelRight, kind: .press, column: 2, row: 3, modes: m),
                       bytes("\u{1b}[<67;3;4M"))
    }

    /// SGR handles arbitrarily large coordinates without wrapping — this is the primary
    /// advantage of mode 1006 over legacy X10.  col=500 (1-based 501), row=300 (301).
    func testSGRLargeCoordinates() {
        let m = modes(any: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 500, row: 300, modes: m),
                       bytes("\u{1b}[<0;501;301M"))
    }

    // MARK: - SGR modifier bits

    /// Modifier bit table (added to the button code):
    ///   Shift  → +4
    ///   Option → +8 (treated as meta/alt in xterm)
    ///   Ctrl   → +16
    /// The drag motion bit (+32) is orthogonal and adds on top.

    func testSGRShiftModifier() {
        let m = modes(click: true, sgr: true)
        // left(0) + shift(4) = 4
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0,
                                           modifiers: .shift, modes: m),
                       bytes("\u{1b}[<4;1;1M"))
    }

    func testSGROptionModifier() {
        let m = modes(click: true, sgr: true)
        // left(0) + option(8) = 8
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0,
                                           modifiers: .option, modes: m),
                       bytes("\u{1b}[<8;1;1M"))
    }

    func testSGRControlModifier() {
        let m = modes(click: true, sgr: true)
        // left(0) + control(16) = 16
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0,
                                           modifiers: .control, modes: m),
                       bytes("\u{1b}[<16;1;1M"))
    }

    /// Combined modifiers: shift(4) + option(8) = 12.
    func testSGRCombinedModifiers() {
        let m = modes(click: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 1, row: 1,
                                           modifiers: [.shift, .option], modes: m),
                       bytes("\u{1b}[<12;2;2M"))
    }

    /// Drag adds 32 on top of button + modifiers.
    /// Here: left(0) + ctrl(16) + drag(32) = 48.
    func testSGRDragWithControl() {
        let m = modes(any: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .drag, column: 0, row: 0,
                                           modifiers: .control, modes: m),
                       bytes("\u{1b}[<48;1;1M"))
    }

    // MARK: - SGR: drag mode vs click mode gating

    /// With mode 1000 (click only), presses must report but drag must not.
    /// With mode 1002 (drag), drag additionally reports. With 1003 (any), motion reports.
    /// The tests below confirm the mode flags gate correctly; they do NOT exercise motion
    /// (the encoder has no "plain motion" path separate from drag — it relies on the
    /// caller to suppress the call for modes that don't track motion).

    /// mode 1000: press reports (returns non-empty).
    func testMode1000AllowsPress() {
        let m = modes(click: true, sgr: true)
        XCTAssertFalse(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0, modes: m).isEmpty)
    }

    /// mode 1002: drag also reports (mouseDrag is set, mouseTrackingEnabled is true).
    func testMode1002AllowsDrag() {
        let m = modes(drag: true, sgr: true)
        XCTAssertFalse(encoder.encodeMouse(button: .left, kind: .drag, column: 0, row: 0, modes: m).isEmpty)
    }

    /// mode 1003: any = mouseAny flag set, mouseTrackingEnabled is true.
    func testMode1003TracksAny() {
        let m = modes(any: true, sgr: true)
        XCTAssertFalse(encoder.encodeMouse(button: .left, kind: .drag, column: 0, row: 0, modes: m).isEmpty)
    }

    // MARK: - Legacy X10 encoding (no mode 1006)

    /// When mouseSGR is false the encoder falls back to the legacy byte form:
    ///   `ESC [ M` + Cb + Cx + Cy
    /// where Cb = button_code + 32, Cx = (col+1) + 32, Cy = (row+1) + 32.
    /// (0-based col/row → 1-based → offset by 32.)
    ///
    /// At origin (col=0, row=0):
    ///   Cb = 0 + 32 = 32   (left press, no modifier, no drag)
    ///   Cx = 1 + 32 = 33
    ///   Cy = 1 + 32 = 33
    func testLegacyX10LeftPressAtOrigin() {
        let m = modes(click: true)  // no SGR
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0, modes: m),
                       [0x1B, 0x5B, 0x4D, 32, 33, 33],
                       "ESC [ M, Cb=32, Cx=33, Cy=33")
    }

    /// At col=4, row=2 (0-based): Cx = (4+1)+32 = 37, Cy = (2+1)+32 = 35.
    func testLegacyX10MiddleCoordinates() {
        let m = modes(click: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 4, row: 2, modes: m),
                       [0x1B, 0x5B, 0x4D, 32, 37, 35])
    }

    /// Right button raw value 2: Cb = 2 + 32 = 34.
    func testLegacyX10RightButton() {
        let m = modes(click: true)
        XCTAssertEqual(encoder.encodeMouse(button: .right, kind: .press, column: 0, row: 0, modes: m),
                       [0x1B, 0x5B, 0x4D, 34, 33, 33])
    }

    // MARK: - Legacy release encoding

    /// In legacy X10 mode, release sets the button code to 3 (low 2 bits forced to 11)
    /// per the xterm spec.  Implementation: `legacy = (legacy & ~0b11) | 3`.
    ///
    /// Left (0): (0 & ~3) | 3 = 3 → Cb = 3 + 32 = 35.
    func testLegacyX10LeftRelease() {
        let m = modes(click: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .release, column: 0, row: 0, modes: m),
                       [0x1B, 0x5B, 0x4D, 35, 33, 33],
                       "release: button bits forced to 3, Cb=35")
    }

    /// Right (2): (2 & ~3) | 3 = 3 → Cb = 35.  Same code as left-release — that is
    /// intentional in the X10 protocol (release always reports button 3).
    func testLegacyX10RightRelease() {
        let m = modes(click: true)
        XCTAssertEqual(encoder.encodeMouse(button: .right, kind: .release, column: 0, row: 0, modes: m),
                       [0x1B, 0x5B, 0x4D, 35, 33, 33])
    }

    // MARK: - Legacy coordinate overflow (clamping behavior pin)

    /// The implementation clamps the 1-based coordinate to 223 before adding the 32 offset:
    ///   cx = UInt8(clamping: min(col, 223) + 32)
    /// So the maximum wire value for Cx/Cy is 223 + 32 = 255 (UInt8.max).
    /// Coordinates at or below 222 (0-based) → 1-based 223 → wire 255.
    /// Coordinates above 222 (0-based) are also clamped to 223 1-based → wire 255.
    ///
    /// This is a BEHAVIOR PIN: the implementation clamps rather than wrapping or omitting.
    func testLegacyX10CoordinateClampAtMax() {
        let m = modes(click: true)
        // 0-based col=222 → 1-based 223 → wire 255 (exactly at ceiling)
        let atCeiling = encoder.encodeMouse(button: .left, kind: .press, column: 222, row: 222, modes: m)
        XCTAssertEqual(atCeiling, [0x1B, 0x5B, 0x4D, 32, 255, 255],
                       "col/row 222 (0-based) → 1-based 223 → wire byte 255")
    }

    /// 0-based col=300 is well past the 223 ceiling; it clamps to the same wire value as 222.
    func testLegacyX10LargeCoordinateClampsToMax() {
        let m = modes(click: true)
        let clamped = encoder.encodeMouse(button: .left, kind: .press, column: 300, row: 300, modes: m)
        XCTAssertEqual(clamped, [0x1B, 0x5B, 0x4D, 32, 255, 255],
                       "col/row beyond 222 clamps to wire byte 255")
    }

    /// col=223 (0-based) → 1-based 224 → min(224,223)+32 = 255.  Still 255.
    func testLegacyX10JustOverCeilingAlsoClamped() {
        let m = modes(click: true)
        let result = encoder.encodeMouse(button: .left, kind: .press, column: 223, row: 0, modes: m)
        XCTAssertEqual(result[3], 32,  "Cb unchanged")
        XCTAssertEqual(result[4], 255, "Cx clamped to 255")
        XCTAssertEqual(result[5], 33,  "Cy = 0+1+32 = 33")
    }

    // MARK: - Legacy modifier bits

    /// xterm modifier bits in the legacy Cb byte (same arithmetic as SGR):
    ///   shift → +4, option → +8, control → +16.
    func testLegacyX10ShiftModifier() {
        let m = modes(click: true)
        // left(0) + shift(4) = 4; Cb = 4 + 32 = 36
        let result = encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0,
                                         modifiers: .shift, modes: m)
        XCTAssertEqual(result[3], 36, "Cb = left(0) + shift(4) + offset(32) = 36")
    }

    func testLegacyX10ControlModifier() {
        let m = modes(click: true)
        // left(0) + ctrl(16) = 16; Cb = 16 + 32 = 48
        let result = encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0,
                                         modifiers: .control, modes: m)
        XCTAssertEqual(result[3], 48, "Cb = left(0) + ctrl(16) + offset(32) = 48")
    }

    // MARK: - DECRQM replies for mouse modes

    /// DECRQM (`CSI ? Ps $ p`) queries the current state of a private mode:
    ///   reply `CSI ? Ps ; 1 $ y` → mode is set
    ///   reply `CSI ? Ps ; 2 $ y` → mode is reset
    ///
    /// This verifies both the response string format and that the state correctly
    /// tracks enable/disable.

    private func collectResponses(_ term: TerminalEmulator, feed input: String) -> [String] {
        var responses: [String] = []
        term.onResponse = { data in
            if let s = String(data: data, encoding: .utf8) { responses.append(s) }
        }
        term.feed(input)
        return responses
    }

    func testDECRQMMode1000ResetState() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        // mode 1000 is off by default; DECRQM should report state=2 (reset)
        let responses = collectResponses(term, feed: "\u{1b}[?1000$p")
        XCTAssertEqual(responses, ["\u{1b}[?1000;2$y"],
                       "mode 1000 reset → state 2 in DECRQM reply")
    }

    func testDECRQMMode1000SetState() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1000h")
        let responses = collectResponses(term, feed: "\u{1b}[?1000$p")
        XCTAssertEqual(responses, ["\u{1b}[?1000;1$y"],
                       "mode 1000 set → state 1 in DECRQM reply")
    }

    func testDECRQMMode1006SetState() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1006h")
        let responses = collectResponses(term, feed: "\u{1b}[?1006$p")
        XCTAssertEqual(responses, ["\u{1b}[?1006;1$y"],
                       "mode 1006 set → state 1 in DECRQM reply")
    }

    func testDECRQMMode1002SetState() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1002h")
        let responses = collectResponses(term, feed: "\u{1b}[?1002$p")
        XCTAssertEqual(responses, ["\u{1b}[?1002;1$y"])
    }

    func testDECRQMMode1003SetState() {
        let term = TerminalEmulator(cols: 40, rows: 10)
        term.feed("\u{1b}[?1003h")
        let responses = collectResponses(term, feed: "\u{1b}[?1003$p")
        XCTAssertEqual(responses, ["\u{1b}[?1003;1$y"])
    }

    // MARK: - Unsupported modes are a no-op

    /// Modes 1005, 1015, and 1016 are NOT implemented.  Feeding their DECSET sequences
    /// must not crash, must not accidentally enable mode 1006 (SGR) behavior, and the
    /// DECRQM reply must report state=0 ("not recognized").
    ///
    /// This is a BEHAVIOR PIN asserting the current no-op handling.
    func testUnsupportedModeIsNoOp() {
        let term = TerminalEmulator(cols: 40, rows: 10)

        // The legacy encodings (UTF-8 1005, urxvt 1015) stay unsupported no-ops; SGR-pixel
        // (1016) is now a recognized encoding mode — but, like 1006, it is an *encoding*,
        // never a tracking tier.
        term.feed("\u{1b}[?1005h")
        term.feed("\u{1b}[?1015h")
        term.feed("\u{1b}[?1016h")

        XCTAssertFalse(term.modes.mouseSGR,
                       "modes 1005/1015/1016 must not enable mouseSGR (mode 1006)")
        XCTAssertTrue(term.modes.mouseSGRPixel, "1016 is supported (ships with the VT polish cluster)")
        XCTAssertFalse(term.modes.mouseTrackingEnabled,
                       "encoding modes must not enable any tracking tier")

        // DECRQM: the unrecognized legacy modes report state=0; 1016 reports its real state.
        var responses: [String] = []
        term.onResponse = { data in
            if let s = String(data: data, encoding: .utf8) { responses.append(s) }
        }
        term.feed("\u{1b}[?1005$p")
        term.feed("\u{1b}[?1015$p")
        term.feed("\u{1b}[?1016$p")
        XCTAssertEqual(responses, ["\u{1b}[?1005;0$y", "\u{1b}[?1015;0$y", "\u{1b}[?1016;1$y"],
                       "legacy modes → state=0; 1016 → its tracked state")
    }

    // MARK: - Any-event motion (1003: kind .move)

    /// Button-less motion encodes the "no button" base (3) + motion bit (32) = 35; SGR
    /// motion uses the 'M' final (only releases use 'm').
    func testMoveEncodesNoButtonPlusMotion() {
        var m = modes(any: true, sgr: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .move, column: 4, row: 2, modes: m),
                       bytes("\u{1b}[<35;5;3M"), "button is ignored for motion — base is 3")

        // Modifiers stack on the motion code (shift +4 → 39).
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .move, column: 0, row: 0,
                                           modifiers: [.shift], modes: m),
                       bytes("\u{1b}[<39;1;1M"))

        // Legacy encoding: Cb = 35 + 32 = 67 ('C').
        m = modes(any: true)
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .move, column: 0, row: 0, modes: m),
                       [0x1B, 0x5B, 0x4D, 67, 33, 33])
    }

    // MARK: - SGR-pixel (1016)

    func testSGRPixelEncodesPixelCoordinatesAndPrecedence() {
        var m = modes(any: true, sgr: true)
        m.mouseSGRPixel = true
        // Pixel coordinates (0-based in, 1-based on the wire), 1016 wins over 1006.
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 4, row: 2,
                                           pixelPosition: (x: 47, y: 31), modes: m),
                       bytes("\u{1b}[<0;48;32M"))
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .release, column: 4, row: 2,
                                           pixelPosition: (x: 47, y: 31), modes: m),
                       bytes("\u{1b}[<0;48;32m"))
        // Motion in pixel mode.
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .move, column: 4, row: 2,
                                           pixelPosition: (x: 9, y: 9), modes: m),
                       bytes("\u{1b}[<35;10;10M"))
    }

    func testSGRPixelWithoutHostPixelsDegradesToCells() {
        var m = modes(click: true, sgr: true)
        m.mouseSGRPixel = true
        // A headless host can't produce pixels: fall back to 1006 cells, never silence.
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 4, row: 2, modes: m),
                       bytes("\u{1b}[<0;5;3M"))
        // …and without 1006 either, to legacy X10 cells.
        var legacy = modes(click: true)
        legacy.mouseSGRPixel = true
        XCTAssertEqual(encoder.encodeMouse(button: .left, kind: .press, column: 0, row: 0, modes: legacy),
                       [0x1B, 0x5B, 0x4D, 32, 33, 33])
    }
}
