import XCTest
@testable import HarnessTerminalEngine

/// Mirrors the original libghostty `HeadlessGridReadTests` contract against the native
/// engine, so the two can be A/B-compared and the engine is held to the same bar:
/// `readGrid()` must faithfully report codepoints, SGR colors (palette + RGB),
/// attributes, wide characters, and the cursor.
final class HarnessGridTerminalTests: XCTestCase {
    private func feedAndRead(
        _ bytes: String,
        cols: Int = 80,
        rows: Int = 24
    ) -> (HarnessGridTerminal, TerminalGridSnapshot)? {
        guard let term = HarnessGridTerminal(cols: cols, rows: rows) else {
            XCTFail("HarnessGridTerminal failed to create")
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
        guard let term = HarnessGridTerminal(cols: 80, rows: 24) else {
            return XCTFail("create failed")
        }
        let grid = term.readGrid()
        XCTAssertEqual(grid?.cols, 80)
        XCTAssertEqual(grid?.rows, 24)
        XCTAssertEqual(grid?.cells.count, 80 * 24)
    }

    func testRejectsZeroSize() {
        XCTAssertNil(HarnessGridTerminal(cols: 0, rows: 24))
        XCTAssertNil(HarnessGridTerminal(cols: 80, rows: 0))
    }

    func testResizeIsExactAndSynchronous() {
        guard let term = HarnessGridTerminal(cols: 80, rows: 24) else {
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
        guard let (_, grid) = feedAndRead("\u{1b}[31mR") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(1))
    }

    func testBrightForegroundPaletteColor() {
        // SGR 91 = bright red (palette index 9).
        guard let (_, grid) = feedAndRead("\u{1b}[91mR") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(9))
    }

    func test256Color() {
        guard let (_, grid) = feedAndRead("\u{1b}[38;5;208mO") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.foreground, .palette(208))
    }

    func testTrueColorBackground() {
        guard let (_, grid) = feedAndRead("\u{1b}[48;2;10;20;30mX") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.background, .rgb(r: 10, g: 20, b: 30))
    }

    func testAttributesBoldItalicUnderline() {
        guard let (_, grid) = feedAndRead("\u{1b}[1;3;4mA") else { return }
        guard let cell = grid.cell(row: 0, col: 0) else { return XCTFail("no cell") }
        XCTAssertTrue(cell.bold)
        XCTAssertTrue(cell.italic)
        XCTAssertEqual(cell.underline, .single)
    }

    func testInverseAttribute() {
        guard let (_, grid) = feedAndRead("\u{1b}[7mI") else { return }
        XCTAssertTrue(grid.cell(row: 0, col: 0)?.inverse ?? false)
    }

    func testSGRResetClearsAttributes() {
        guard let (_, grid) = feedAndRead("\u{1b}[1;31mA\u{1b}[0mB") else { return }
        XCTAssertTrue(grid.cell(row: 0, col: 0)?.bold ?? false)
        XCTAssertFalse(grid.cell(row: 0, col: 1)?.bold ?? true)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.foreground, TerminalGridColor.none)
    }

    func testWideCharacter() {
        guard let (_, grid) = feedAndRead("世") else { return }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.width, .wide)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.width, .spacerTail)
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, 0x4E16)
    }

    func testCursorPosition() {
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
