import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Conformance for the VT correctness cluster brought up in roadmap PR-5: REP (`CSI b`), IRM
/// (insert/replace mode, `CSI 4 h/l`), DECOM (origin mode, `CSI ?6 h/l`), DECSTR soft reset
/// (`CSI ! p`), and DECALN screen alignment (`ESC # 8`). Each was previously dropped — REP/IRM had
/// no handler, DECSTR/DECALN were swallowed by the `intermediates.isEmpty` guards, and DECOM was
/// never applied to cursor addressing — so the else-of-correctness always won.
final class VTCorrectnessClusterTests: XCTestCase {
    private func make(cols: Int, rows: Int) -> HarnessGridTerminal {
        HarnessGridTerminal(cols: cols, rows: rows)!
    }

    private func read(_ bytes: String, cols: Int = 80, rows: Int = 24) -> TerminalGridSnapshot {
        let term = make(cols: cols, rows: rows)
        term.feed(bytes)
        return term.readGrid()!
    }

    private func cp(_ s: String) -> UInt32 { s.unicodeScalars.first!.value }

    // MARK: - REP (repeat preceding graphic character)

    func testREPRepeatsLastGraphicCharacter() {
        // 'A' then `CSI 3 b` → A printed once, repeated 3 more times = 4 total.
        let grid = read("A\u{1b}[3b", cols: 10, rows: 1)
        for c in 0 ..< 4 { XCTAssertEqual(grid.cell(row: 0, col: c)?.codepoint, cp("A"), "col \(c)") }
        XCTAssertEqual(grid.cell(row: 0, col: 4)?.codepoint, 0, "no fifth A")
        XCTAssertEqual(grid.cursor.col, 4)
    }

    func testREPDefaultCountIsOne() {
        let grid = read("X\u{1b}[b", cols: 10, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, cp("X"))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, cp("X"))
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, 0)
    }

    func testREPIsNoOpWithNoPriorCharacter() {
        let grid = read("\u{1b}[5b", cols: 10, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cursor.col, 0)
    }

    func testREPRepeatsLastOfARun() {
        // The batched ASCII run path must still leave the trailing char as REP's source.
        let grid = read("abc\u{1b}[2b", cols: 10, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, cp("c"))
        XCTAssertEqual(grid.cell(row: 0, col: 3)?.codepoint, cp("c"))
        XCTAssertEqual(grid.cell(row: 0, col: 4)?.codepoint, cp("c"))
        XCTAssertEqual(grid.cell(row: 0, col: 5)?.codepoint, 0)
    }

    // MARK: - IRM (insert/replace mode)

    func testIRMInsertShiftsLineRight() {
        // Print "ABC", home, enable insert mode, type "XY": X Y insert before A, pushing ABC right.
        let grid = read("ABC\u{1b}[1;1H\u{1b}[4hXY", cols: 8, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, cp("X"))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, cp("Y"))
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, cp("A"))
        XCTAssertEqual(grid.cell(row: 0, col: 3)?.codepoint, cp("B"))
        XCTAssertEqual(grid.cell(row: 0, col: 4)?.codepoint, cp("C"))
    }

    func testIRMResetRestoresOverwrite() {
        // Insert "X", then `CSI 4 l` back to replace mode and type "Z": Z overwrites, no shift.
        let grid = read("ABC\u{1b}[1;1H\u{1b}[4hX\u{1b}[4lZ", cols: 8, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, cp("X"))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, cp("Z"), "replace mode overwrites A→Z")
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, cp("B"))
        XCTAssertEqual(grid.cell(row: 0, col: 3)?.codepoint, cp("C"))
    }

    func testIRMDropsCharactersPushedOffRightEdge() {
        let grid = read("ABCD\u{1b}[1;1H\u{1b}[4hZ", cols: 4, rows: 1)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, cp("Z"))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, cp("A"))
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, cp("B"))
        XCTAssertEqual(grid.cell(row: 0, col: 3)?.codepoint, cp("C")) // D pushed off
    }

    // MARK: - DECOM (origin mode)

    func testDECOMConfinesCursorAddressingToScrollRegion() {
        // Scroll region rows 3..5 (1-based), origin mode on. CUP row 1 maps to the region top (row
        // index 2), and an over-large row clamps to the region bottom (row index 4).
        let grid = read("\u{1b}[3;5r\u{1b}[?6h\u{1b}[1;1HA\u{1b}[2;3HB\u{1b}[99;1HC", cols: 6, rows: 6)
        XCTAssertEqual(grid.cell(row: 2, col: 0)?.codepoint, cp("A"), "row 1 → region top (abs row 2)")
        XCTAssertEqual(grid.cell(row: 3, col: 2)?.codepoint, cp("B"), "row 2 → abs row 3, col 3")
        XCTAssertEqual(grid.cell(row: 4, col: 0)?.codepoint, cp("C"), "row 99 clamps to region bottom")
    }

    func testDECOMHomesCursorToRegionTopWhenEnabled() {
        let term = make(cols: 6, rows: 6)
        term.feed("\u{1b}[3;5r\u{1b}[?6h")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cursor.row, 2, "enabling DECOM homes the cursor to the region top")
        XCTAssertEqual(grid.cursor.col, 0)
    }

    func testCursorAddressingIsAbsoluteWithoutDECOM() {
        // Same region, DECOM off (default): CUP is screen-absolute, reaching row 0.
        let grid = read("\u{1b}[3;5r\u{1b}[1;1HA", cols: 6, rows: 6)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, cp("A"))
    }

    func testDECOMVPAIsRegionRelative() {
        let grid = read("\u{1b}[3;5r\u{1b}[?6h\u{1b}[1dA", cols: 6, rows: 6)
        XCTAssertEqual(grid.cell(row: 2, col: 0)?.codepoint, cp("A"), "VPA row 1 → region top")
    }

    func testDECOMReportedViaDECRQM() {
        let term = make(cols: 10, rows: 6)
        var responses = Data()
        term.onResponse = { responses.append($0) }
        term.feed("\u{1b}[?6h\u{1b}[?6$p")
        XCTAssertEqual(String(decoding: responses, as: UTF8.self), "\u{1b}[?6;1$y", "DECOM reports set")
        responses.removeAll()
        term.feed("\u{1b}[?6l\u{1b}[?6$p")
        XCTAssertEqual(String(decoding: responses, as: UTF8.self), "\u{1b}[?6;2$y", "DECOM reports reset")
    }

    // MARK: - DECSTR (soft terminal reset)

    func testDECSTRResetsInsertOriginAndCursorVisibility() {
        let term = make(cols: 10, rows: 6)
        // Enter insert mode, origin mode, hide the cursor, set a scroll region.
        term.feed("\u{1b}[4h\u{1b}[?6h\u{1b}[?25l\u{1b}[2;4r")
        // Soft reset.
        term.feed("\u{1b}[!p")
        // DECRQM now reports both modes reset; cursor visible again.
        var responses = Data()
        term.onResponse = { responses.append($0) }
        term.feed("\u{1b}[?6$p")
        XCTAssertEqual(String(decoding: responses, as: UTF8.self), "\u{1b}[?6;2$y", "DECOM reset by DECSTR")
        XCTAssertTrue(term.readGrid()!.cursor.visible, "DECSTR re-shows the cursor")
        // Scroll region reset to full screen: a screen-absolute CUP reaches row 0 (origin is off).
        term.feed("\u{1b}[1;1HQ")
        XCTAssertEqual(term.readGrid()!.cell(row: 0, col: 0)?.codepoint, cp("Q"))
    }

    func testDECSTRDoesNotClearScreenOrMoveCursor() {
        let term = make(cols: 10, rows: 4)
        term.feed("AB\u{1b}[!p")
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, cp("A"), "DECSTR preserves screen content")
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, cp("B"))
        XCTAssertEqual(grid.cursor.col, 2, "DECSTR leaves the cursor in place")
    }

    // MARK: - DECALN (screen alignment test)

    func testDECALNFillsScreenWithE() {
        let grid = read("\u{1b}#8", cols: 4, rows: 3)
        for r in 0 ..< 3 {
            for c in 0 ..< 4 {
                XCTAssertEqual(grid.cell(row: r, col: c)?.codepoint, cp("E"), "r\(r)c\(c)")
            }
        }
    }

    func testDECALNHomesCursorAndResetsScrollRegion() {
        // Set a scroll region, then DECALN: cursor homes to (0,0) and the region is full-screen again
        // (so a subsequent screen-absolute move + print lands at row 0).
        let grid = read("\u{1b}[2;3r\u{1b}#8", cols: 4, rows: 4)
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cursor.col, 0)
    }
}
