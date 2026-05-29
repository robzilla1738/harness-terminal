import Foundation
import GhosttyTerminal
import XCTest

/// Validates the forked styled-grid read API end-to-end through `GridTerminal`,
/// the renderer-free headless terminal (`ghostty_terminal_*`). This is the
/// primitive the `harness attach` compositor uses: a pure VT state machine with
/// no renderer / Metal / NSView, safe to create, drive, resize, and destroy.
///
/// `readGrid()` must faithfully report codepoints, SGR colors (palette + RGB),
/// attributes, wide characters, and the cursor.
final class HeadlessGridReadTests: XCTestCase {
    private func feedAndRead(
        _ bytes: String,
        cols: Int = 80,
        rows: Int = 24
    ) -> (GridTerminal, TerminalGridSnapshot)? {
        guard let term = GridTerminal(cols: cols, rows: rows) else {
            XCTFail("GridTerminal failed to create")
            return nil
        }
        term.feed(bytes)
        guard let grid = term.readGrid() else {
            XCTFail("readGrid returned nil")
            return nil
        }
        return (term, grid)
    }

    func testCreatesAtExactSize() {
        guard let term = GridTerminal(cols: 80, rows: 24) else {
            return XCTFail("create failed")
        }
        let grid = term.readGrid()
        XCTAssertNotNil(grid)
        XCTAssertEqual(grid?.cols, 80)
        XCTAssertEqual(grid?.rows, 24)
        XCTAssertEqual(grid?.cells.count, 80 * 24)
    }

    func testResizeIsExactAndSynchronous() {
        guard let term = GridTerminal(cols: 80, rows: 24) else {
            return XCTFail("create failed")
        }
        term.resize(cols: 120, rows: 40)
        let grid = term.readGrid()
        XCTAssertEqual(grid?.cols, 120)
        XCTAssertEqual(grid?.rows, 40)
        XCTAssertEqual(grid?.cells.count, 120 * 40)
    }

    func testPlainTextLandsInCells() {
        guard let (_, grid) = feedAndRead("Hello") else { return }
        let expected = Array("Hello".unicodeScalars).map { UInt32($0.value) }
        for (i, cp) in expected.enumerated() {
            XCTAssertEqual(grid.cell(row: 0, col: i)?.codepoint, cp, "mismatch at col \(i)")
        }
    }

    func testForegroundPaletteColor() {
        // SGR 31 = red (palette index 1).
        guard let (_, grid) = feedAndRead("\u{1b}[31mR") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(1))
    }

    func test256Color() {
        // SGR 38;5;208 = palette index 208 foreground.
        guard let (_, grid) = feedAndRead("\u{1b}[38;5;208mO") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(208))
    }

    func testTrueColorBackground() {
        // SGR 48;2;10;20;30 = direct RGB background.
        guard let (_, grid) = feedAndRead("\u{1b}[48;2;10;20;30mX") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.background, .rgb(r: 10, g: 20, b: 30))
    }

    func testAttributesBoldItalicUnderline() {
        // Bold + italic + single underline.
        guard let (_, grid) = feedAndRead("\u{1b}[1;3;4mA") else { return }
        guard let cell = grid.cell(row: 0, col: 0) else { return XCTFail("no cell") }
        XCTAssertTrue(cell.bold, "bold not set")
        XCTAssertTrue(cell.italic, "italic not set")
        XCTAssertEqual(cell.underline, .single, "underline not single")
    }

    func testInverseAttribute() {
        guard let (_, grid) = feedAndRead("\u{1b}[7mI") else { return }
        XCTAssertTrue(grid.cell(row: 0, col: 0)?.inverse ?? false, "inverse not set")
    }

    func testWideCharacter() {
        // CJK ideograph occupies two cells: a wide cell + a spacer tail.
        guard let (_, grid) = feedAndRead("世") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.width, .wide, "first cell should be wide")
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.width, .spacerTail, "second cell should be spacer tail")
    }

    func testCursorPosition() {
        // Move cursor to row 5, col 10 (1-based CSI -> 0-based grid).
        guard let (_, grid) = feedAndRead("\u{1b}[5;10H") else { return }
        XCTAssertEqual(grid.cursor.row, 4)
        XCTAssertEqual(grid.cursor.col, 9)
        XCTAssertTrue(grid.cursor.visible)
    }

    func testNewlinesAdvanceRows() {
        guard let (_, grid) = feedAndRead("a\r\nb\r\nc") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, UInt32(UnicodeScalar("a").value))
        XCTAssertEqual(grid.cell(row: 1, col: 0)?.codepoint, UInt32(UnicodeScalar("b").value))
        XCTAssertEqual(grid.cell(row: 2, col: 0)?.codepoint, UInt32(UnicodeScalar("c").value))
    }
}
