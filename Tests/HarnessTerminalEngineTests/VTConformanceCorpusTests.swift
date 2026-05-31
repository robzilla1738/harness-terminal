import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// vttest-style golden-snapshot conformance: feed a known control sequence, then compare the
/// *entire* rendered grid against an expected text block. Where `EngineConformanceTests` asserts
/// individual cells/cursor, these lock the whole-screen result of combined operations (cursor
/// addressing, erase, tab stops, line editing) so a regression in any of them shows as a diff.
final class VTConformanceCorpusTests: XCTestCase {
    /// Render the visible grid to text: one line per row, codepoint 0/space → space, trailing
    /// blanks trimmed per row, rows joined by "\n" (trailing blank rows trimmed too).
    private func render(_ bytes: String, cols: Int, rows: Int) -> String {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(bytes)
        let grid = term.readGrid()!
        var lines: [String] = []
        for r in 0 ..< rows {
            var line = ""
            for c in 0 ..< cols {
                let cp = grid.cell(row: r, col: c)?.codepoint ?? 0
                line.append((cp == 0 || cp == 0x20) ? " " : String(UnicodeScalar(cp) ?? " "))
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    func testCursorAddressingGolden() {
        // CUP (`ESC [ row;col H`) places each pair at the addressed cell, 1-based.
        let out = render("\u{1b}[1;1HAB\u{1b}[2;3HCD\u{1b}[3;5HEF", cols: 6, rows: 3)
        XCTAssertEqual(out, "AB\n  CD\n    EF")
    }

    func testEraseInLineGolden() {
        // Fill three rows, then EL-0 from (row 2, col 3) clears that row's tail.
        let out = render("AAAAA\r\nBBBBB\r\nCCCCC\u{1b}[2;3H\u{1b}[K", cols: 5, rows: 3)
        XCTAssertEqual(out, "AAAAA\nBB\nCCCCC")
    }

    func testTabStopsGolden() {
        // Default tab stops every 8 columns: A@0, B@8, C@16.
        let out = render("A\tB\tC", cols: 20, rows: 1)
        XCTAssertEqual(out, "A       B       C")
    }

    func testInsertLineGolden() {
        // IL (`ESC [ L`) at the top pushes existing rows down; the bottom row falls off.
        let out = render("AAA\r\nBBB\r\nCCC\r\nDDD\u{1b}[1;1H\u{1b}[L", cols: 3, rows: 4)
        XCTAssertEqual(out, "\nAAA\nBBB\nCCC")
    }

    func testDeleteLineGolden() {
        // DL (`ESC [ M`) at the top pulls lower rows up; a blank line enters at the bottom.
        let out = render("AAA\r\nBBB\r\nCCC\r\nDDD\u{1b}[1;1H\u{1b}[M", cols: 3, rows: 4)
        XCTAssertEqual(out, "BBB\nCCC\nDDD")
    }

    func testScrollRegionGolden() {
        // DECSTBM rows 2–3: a line feed at the region's bottom scrolls only those rows; row 1 and
        // row 4 stay put. Fill, set region, park at row 3, then RI/LF interplay via explicit CUP.
        // Here: write 1..4, set region 2;3, go to (3,1), and LF once → row2⇐row3, row3 blank.
        let out = render("11\r\n22\r\n33\r\n44\u{1b}[2;3r\u{1b}[3;1H\n", cols: 2, rows: 4)
        XCTAssertEqual(out, "11\n33\n\n44")
    }
}
