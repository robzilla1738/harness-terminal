import XCTest
@testable import HarnessTerminalEngine

/// Scrollback: lines that scroll off the top of the primary screen are retained and
/// readable via `readGrid(scrollbackOffset:)`; the alternate screen records nothing.
final class ScrollbackTests: XCTestCase {
    private func char(_ snap: TerminalGridSnapshot, _ row: Int, _ col: Int) -> Character? {
        guard let cp = snap.cell(row: row, col: col)?.codepoint, cp != 0,
              let scalar = Unicode.Scalar(cp) else { return nil }
        return Character(scalar)
    }

    func testLinesScrollIntoHistory() {
        let term = TerminalEmulator(cols: 10, rows: 3)
        term.feed("A\r\nB\r\nC\r\nD\r\nE\r\n")
        // 5 lines fed into 3 rows: A, B, C scrolled off; D, E remain.
        XCTAssertEqual(term.historyCount, 3)

        let live = term.readGrid()
        XCTAssertEqual(char(live, 0, 0), "D")
        XCTAssertEqual(char(live, 1, 0), "E")

        // Scrolled up by 1: top line becomes the most recent history line (C).
        let up1 = term.readGrid(scrollbackOffset: 1)
        XCTAssertEqual(char(up1, 0, 0), "C")
        XCTAssertEqual(char(up1, 1, 0), "D")
        XCTAssertEqual(char(up1, 2, 0), "E")
        XCTAssertFalse(up1.cursor.visible) // cursor hidden while scrolled back

        // Scrolled to the oldest: A, B, C.
        let up3 = term.readGrid(scrollbackOffset: 3)
        XCTAssertEqual(char(up3, 0, 0), "A")
        XCTAssertEqual(char(up3, 2, 0), "C")

        // Over-scroll clamps to the available history.
        XCTAssertEqual(term.readGrid(scrollbackOffset: 99).cells, up3.cells)
    }

    func testHistoryCapDropsOldest() {
        let term = TerminalEmulator(cols: 4, rows: 2)
        term.maxScrollbackLines = 2
        for i in 0 ..< 10 { term.feed("\(i)\r\n") }
        XCTAssertEqual(term.historyCount, 2)
    }

    func testAlternateScreenRecordsNoHistory() {
        let term = TerminalEmulator(cols: 8, rows: 2)
        term.feed("\u{1b}[?1049h") // enter alternate screen
        term.feed("X\r\nY\r\nZ\r\n")
        XCTAssertEqual(term.historyCount, 0)
    }
}
