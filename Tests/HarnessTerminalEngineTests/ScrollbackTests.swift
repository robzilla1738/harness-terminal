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

    private func osc133(_ body: String) -> String { "\u{1b}]133;\(body)\u{07}" }

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

    // Cap 3 (slack `maxHistoryLines/4` == 0) → the cap is enforced exactly, so these assertions
    // are deterministic. Feeding 0…9 pushes 0…8 into scrollback; the cap keeps the newest 3 (6,7,8)
    // with "9" live, exercising the ring buffer's drop-oldest path.
    func testOldLinesDroppedInCorrectOrder() {
        let term = TerminalEmulator(cols: 4, rows: 2)
        term.maxScrollbackLines = 3
        for i in 0 ..< 10 { term.feed("\(i)\r\n") }
        XCTAssertEqual(term.historyCount, 3)
        // Oldest retained is the most-recent survivor (6), not the original first line (0).
        let oldest = term.readGrid(scrollbackOffset: term.historyCount)
        XCTAssertEqual(char(oldest, 0, 0), "6", "oldest retained line is 6")
        XCTAssertEqual(char(oldest, 1, 0), "7")
    }

    func testScrollbackSnapshotAfterCapExceeded() {
        let term = TerminalEmulator(cols: 4, rows: 2)
        term.maxScrollbackLines = 3
        for i in 0 ..< 10 { term.feed("\(i)\r\n") }
        // Live view shows the last line; scrolling up crosses the history→viewport boundary.
        XCTAssertEqual(char(term.readGrid(), 0, 0), "9")
        let up1 = term.readGrid(scrollbackOffset: 1)
        XCTAssertEqual(char(up1, 0, 0), "8", "newest history line")
        XCTAssertEqual(char(up1, 1, 0), "9", "then the live row")
    }

    func testCapturePaneAfterCapExceeded() {
        let term = TerminalEmulator(cols: 4, rows: 2)
        term.maxScrollbackLines = 3
        for i in 0 ..< 10 { term.feed("\(i)\r\n") }
        // history (6,7,8) ++ viewport (9, blank) — only the survivors, in order.
        let lines = term.captureLines(joinWrapped: false)
        XCTAssertEqual(Array(lines.prefix(4)), ["6", "7", "8", "9"])
    }

    func testReflowAfterCapExceeded() {
        let term = TerminalEmulator(cols: 4, rows: 2)
        term.maxScrollbackLines = 3
        for i in 0 ..< 10 { term.feed("\(i)\r\n") }
        XCTAssertEqual(term.historyCount, 3)
        term.resize(cols: 6, rows: 3)
        XCTAssertLessThanOrEqual(term.historyCount, 3, "cap still respected after reflow")
        // Reflow preserves the surviving lines and their order (trailing blanks aside).
        let surviving = term.captureLines(joinWrapped: false).filter { !$0.isEmpty }
        XCTAssertEqual(surviving, ["6", "7", "8", "9"])
    }

    func testPromptMarksSurviveScrollingAndCapTrimming() {
        let term = TerminalEmulator(cols: 8, rows: 2)
        term.maxScrollbackLines = 3
        // A marked prompt line, then scroll it up into scrollback (still within the cap).
        term.feed(osc133("A") + "PROMPT\r\n")
        term.feed("a\r\n")
        XCTAssertEqual(term.promptRows.count, 1, "the prompt mark rides into scrollback")
        XCTAssertNotNil(term.mark(atBufferLine: term.promptRows[0]), "mark readable at its buffer line")
        // Overflow the cap with unmarked lines; the marked line is dropped along with it.
        for i in 0 ..< 12 { term.feed("u\(i)\r\n") }
        XCTAssertEqual(term.historyCount, 3)
        XCTAssertTrue(term.promptRows.isEmpty, "the trimmed prompt's mark is gone")
    }

    func testAlternateScreenRecordsNoHistory() {
        let term = TerminalEmulator(cols: 8, rows: 2)
        term.feed("\u{1b}[?1049h") // enter alternate screen
        term.feed("X\r\nY\r\nZ\r\n")
        XCTAssertEqual(term.historyCount, 0)
    }
}
