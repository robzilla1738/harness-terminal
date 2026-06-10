import XCTest
@testable import HarnessDaemonCore

/// Roadmap PR-11: direct coverage for `RealPty.stripANSI`, the hand-rolled escape filter behind
/// `capture-pane` (without `-e`) and `captureRange`. These are pure-string cases — no PTY spawn —
/// so they run everywhere; the live `captureRange` range math is covered by the live daemon tests.
final class RealPtyCaptureTests: XCTestCase {
    func testStripsSGR() {
        XCTAssertEqual(RealPty.stripANSI("\u{1b}[31mRED\u{1b}[0m"), "RED")
        XCTAssertEqual(RealPty.stripANSI("\u{1b}[1;38;5;200mx\u{1b}[m"), "x")
    }

    func testStripsOSCTerminatedByBEL() {
        // OSC 0 (window title) ended by BEL, then real text.
        XCTAssertEqual(RealPty.stripANSI("\u{1b}]0;my title\u{07}body"), "body")
    }

    func testStripsOSCTerminatedByST() {
        // OSC 8 hyperlink wrapper (ESC \ terminator) — only the visible label survives.
        let hyperlink = "\u{1b}]8;;https://example.com\u{1b}\\label\u{1b}]8;;\u{1b}\\"
        XCTAssertEqual(RealPty.stripANSI(hyperlink), "label")
    }

    func testStripsTruncatedCSIAtEndOfInput() {
        // A capture that ends mid-CSI (no final byte) must not leak the partial escape.
        XCTAssertEqual(RealPty.stripANSI("abc\u{1b}[31"), "abc")
        XCTAssertEqual(RealPty.stripANSI("abc\u{1b}["), "abc")
    }

    func testStripsDCSAndOtherC1StringControls() {
        // DCS reply (DECRQSS-style payload contains the letters that used to leak through).
        XCTAssertEqual(RealPty.stripANSI("A\u{1b}P1$r0;1m\u{1b}\\B"), "AB")
        // SOS / PM / APC are the same ST-terminated family.
        XCTAssertEqual(RealPty.stripANSI("\u{1b}Xsos data\u{1b}\\Y"), "Y")
        XCTAssertEqual(RealPty.stripANSI("\u{1b}^pm data\u{07}Z"), "Z")
        XCTAssertEqual(RealPty.stripANSI("\u{1b}_apc data\u{1b}\\W"), "W")
    }

    func testStripsCharsetSelectionAndStrayControls() {
        // ESC ( B (designate ASCII) is a two-byte escape; a stray C0 control (0x01) is dropped.
        XCTAssertEqual(RealPty.stripANSI("\u{1b}(BX\u{01}Y"), "XY")
    }

    func testKeepsNewlinesAndTabs() {
        // Newlines and tabs are structural and must survive; other C0 controls are stripped.
        XCTAssertEqual(RealPty.stripANSI("a\u{1b}[0mb\nc\td\u{08}e"), "ab\nc\tde")
    }

    func testPlainTextIsUnchanged() {
        XCTAssertEqual(RealPty.stripANSI("plain café 中 text"), "plain café 中 text")
    }
}
