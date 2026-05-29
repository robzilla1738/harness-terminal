import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Behavioral conformance for control functions beyond the basic read-grid contract:
/// autowrap, scrolling, erase/edit, cursor save/restore, UTF-8, alternate screen, and
/// PTY responses (DSR/DA). These are the correctness surfaces the A/B oracle (vs the
/// the renderer fork) will also exercise during cutover.
final class EngineConformanceTests: XCTestCase {
    private func read(_ bytes: String, cols: Int = 80, rows: Int = 24) -> TerminalGridSnapshot {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(bytes)
        return term.readGrid()!
    }

    func testAutowrapToNextLine() {
        let line = String(repeating: "a", count: 80) + "b"
        let grid = read(line, cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 79)?.codepoint, UInt32(UnicodeScalar("a").value))
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, UInt32(UnicodeScalar("b").value))
        XCTAssertEqual(grid.cursor.row, 1)
        XCTAssertEqual(grid.cursor.col, 1)
    }

    func testAutowrapDisabledOverwritesLastColumn() {
        // ?7l disables DECAWM; subsequent glyphs pile up on the last column.
        let grid = read("\u{1b}[?7l" + String(repeating: "a", count: 80) + "XY", cols: 80, rows: 24)
        XCTAssertEqual(grid.cursor.row, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 79)?.codepoint, UInt32(UnicodeScalar("Y").value))
    }

    func testLineFeedScrollsAtBottom() {
        let grid = read("a\r\nb\r\nc\r\nd", cols: 10, rows: 3)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("b").value))
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertEqual(grid.cell(row: 2, col: 0)?.codepoint, UInt32(UnicodeScalar("d").value))
    }

    func testEraseInLine() {
        let grid = read("hello\u{1b}[2K", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 4)?.codepoint, 0)
    }

    func testEraseInDisplayClearsEverything() {
        let grid = read("line1\r\nline2\u{1b}[2J", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, 0)
    }

    func testDeleteCharactersShiftsLeft() {
        // "abcdef", home, DCH 2 -> "cdef".
        let grid = read("abcdef\u{1b}[H\u{1b}[2P", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("c").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("d").value))
    }

    func testInsertCharactersShiftsRight() {
        // "abc", home, ICH 2 -> "  abc".
        let grid = read("abc\u{1b}[H\u{1b}[2@", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, 0)
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, UInt32(UnicodeScalar("a").value))
    }

    func testSaveRestoreCursor() {
        let grid = read("\u{1b}[5;5H\u{1b}7\u{1b}[10;10H\u{1b}8", cols: 80, rows: 24)
        XCTAssertEqual(grid.cursor.row, 4)
        XCTAssertEqual(grid.cursor.col, 4)
    }

    func testUTF8MultibyteDecoding() {
        // "héllo": é = U+00E9 (2-byte UTF-8).
        let grid = read("héllo", cols: 80, rows: 24)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0x68)   // h
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, 0xE9)   // é
        XCTAssertEqual(grid.cell(row: 0, col: 2)?.codepoint, 0x6C)   // l
    }

    func testCursorVisibilityMode() {
        XCTAssertFalse(read("\u{1b}[?25l").cursor.visible)
        XCTAssertTrue(read("\u{1b}[?25l\u{1b}[?25h").cursor.visible)
    }

    func testResizePreservesTopLeftContent() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        term.feed("hi")
        term.resize(cols: 100, rows: 50)
        let grid = term.readGrid()!
        XCTAssertEqual(grid.cols, 100)
        XCTAssertEqual(grid.rows, 50)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("h").value))
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, UInt32(UnicodeScalar("i").value))
    }

    func testAlternateScreenSwapAndRestore() {
        let term = HarnessGridTerminal(cols: 80, rows: 24)!
        term.feed("primary")
        term.feed("\u{1b}[?1049h") // enter alt + clear
        term.feed("alt")
        var grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("a").value))
        term.feed("\u{1b}[?1049l") // leave alt -> primary restored
        grid = term.readGrid()!
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("p").value))
    }

    func testDeviceStatusReportRespondsWithCursorPosition() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[3;7H\u{1b}[6n")
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}[3;7R")
    }

    func testDeviceAttributesResponse() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[c")
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}[?1;2c")
    }

    func testTitleOSC() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var title: String?
        emu.onTitleChange = { title = $0 }
        emu.feed("\u{1b}]0;My Title\u{07}")
        XCTAssertEqual(title, "My Title")
    }

    func testBellExecutes() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var rang = false
        emu.onBell = { rang = true }
        emu.feed("\u{07}")
        XCTAssertTrue(rang)
    }

    func testCurlyUnderlineSubparam() {
        // SGR 4:3 = curly underline (colon sub-parameter form).
        let grid = read("\u{1b}[4:3mA")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.underline, .curly)
    }

    func testDottedAndDashedUnderlineSubparams() {
        XCTAssertEqual(read("\u{1b}[4:4mA").cell(row: 0, col: 0)?.underline, .dotted)
        XCTAssertEqual(read("\u{1b}[4:5mA").cell(row: 0, col: 0)?.underline, .dashed)
    }

    func testColonForm256Color() {
        let grid = read("\u{1b}[38:5:208mO")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(208))
    }

    func testColonFormTrueColor() {
        // 38:2:r:g:b (no colorspace id slot).
        let grid = read("\u{1b}[38:2:10:20:30mX")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .rgb(r: 10, g: 20, b: 30))
    }

    func testColonFormTrueColorWithColorspaceSlot() {
        // 38:2::r:g:b (empty colorspace id) -> group [38,2,0,10,20,30].
        let grid = read("\u{1b}[38:2::10:20:30mX")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .rgb(r: 10, g: 20, b: 30))
    }

    func testUnderlineColorSemicolon() {
        let grid = read("\u{1b}[4;58;5;9mU")
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.underline, .single)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.underlineColor, .palette(9))
    }

    func testScrollRegionConstrainsLineFeed() {
        // Set region rows 1..2 (1-based 2;3), fill, ensure scroll stays inside region.
        let term = HarnessGridTerminal(cols: 10, rows: 4)!
        term.feed("\u{1b}[2;3r")      // DECSTBM rows 2..3 -> homes cursor
        term.feed("\u{1b}[2;1HA\r\nB\r\nC") // print within region, force a scroll
        let grid = term.readGrid()!
        // Row 0 (outside region) must stay untouched/blank.
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0)
    }
}
