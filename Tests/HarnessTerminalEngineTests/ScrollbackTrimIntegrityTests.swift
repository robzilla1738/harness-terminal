import XCTest
@testable import HarnessTerminalEngine

/// Validates `TerminalScreen.scrollUp`'s amortized scrollback-trim logic after a
/// large number of lines pushes the history well past `maxScrollbackLines`.
///
/// **The amortized trim** — to avoid an O(history) `removeFirst` on every scrolled line,
/// `scrollUp` lets the ring buffer overshoot by a bounded slack:
///
///   `slack = min(1024, maxHistoryLines / 4)`
///
/// When `history.count > maxHistoryLines + slack` the engine trims back to exactly
/// `maxHistoryLines`.  With `maxScrollbackLines = 50`:
///   `slack = min(1024, 50/4) = min(1024, 12) = 12`
///
/// So the _maximum_ `historyCount` observable at any time is `50 + 12 = 62`, and the count
/// observed after an arbitrary feed is phase-dependent within `50 ... 62`; each trim cuts
/// back to exactly 50.
///
/// **Setup** — every line fed has the form:
///   `"line NNN 宽 ESC[31m red ESC[0m tail\r\n"`
/// This:
///   • Gives each line a unique, parseable decimal index.
///   • Embeds a CJK wide character to exercise wide-head / spacer-tail pairing.
///   • Applies SGR red foreground so attributes survive on the line's cells.
///
/// **Assertions**:
///   (a) `historyCount ≤ cap + slack` after overflow.
///   (b) Immediately after a trim, `historyCount` is exactly `cap`.
///   (c) The oldest retained line has the correct line index (no off-by-one).
///   (d) Attributes (foreground color) survive on the oldest retained line.
///   (e) Wide-char head+spacerTail pairing is intact on every retained line.
///   (f) `captureLines` text matches the expected line numbers.
///   (g) `bufferLineCount == historyCount + rows`.
final class ScrollbackTrimIntegrityTests: XCTestCase {

    // MARK: - Configuration

    private let cap  = 50    // maxScrollbackLines
    private let ncol = 40    // terminal width
    private let nrow = 4     // viewport rows
    private let totalFed = 300 // lines fed, well past cap + viewport

    /// The slack formula from `scrollUp`: `min(1024, maxHistoryLines / 4)`.
    private var slack: Int { min(1024, cap / 4) }

    // MARK: - Helpers

    /// Build the terminal with the requested scrollback cap and feed `totalFed` numbered lines.
    private func buildEmulator() -> TerminalEmulator {
        let term = TerminalEmulator(cols: ncol, rows: nrow)
        term.maxScrollbackLines = cap
        for i in 0 ..< totalFed {
            term.feed(line(i))
        }
        return term
    }

    /// A single numbered line with a wide char and a red-colored word.
    /// Format: "line NNN 宽 \e[31mred\e[0m tail\r\n"
    private func line(_ i: Int) -> String {
        let num = String(format: "%03d", i)
        return "line \(num) 宽 \u{1b}[31mred\u{1b}[0m tail\r\n"
    }

    /// Extract the decimal line number from a `captureLines` string of the form
    /// "line NNN 宽 …".  Returns nil if parsing fails.
    private func lineNumber(fromCaptured s: String) -> Int? {
        // Expected prefix: "line NNN …"
        let parts = s.split(separator: " ", maxSplits: 3)
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    /// The first non-empty `captureLines` entry after history lines (excluding viewport).
    private func character(in snapshot: TerminalGridSnapshot, row: Int, col: Int) -> Character? {
        guard let cp = snapshot.cell(row: row, col: col)?.codepoint, cp != 0,
              let scalar = Unicode.Scalar(cp) else { return nil }
        return Character(scalar)
    }

    // MARK: - (a) historyCount ≤ cap + slack bound

    /// After overflowing the cap by a wide margin, `historyCount` must never exceed
    /// `cap + slack`.  The amortized trim may leave a transient overshoot up to slack,
    /// but never more.
    func testHistoryCountDoesNotExceedCapPlusSlack() {
        let term = buildEmulator()
        XCTAssertLessThanOrEqual(term.historyCount, cap + slack,
                                 "historyCount \(term.historyCount) > cap(\(cap)) + slack(\(slack))")
    }

    // MARK: - (b) historyCount settles to exactly cap after enough overflow

    /// Each trim fires when `count > cap + slack` and cuts back to exactly `cap`. The count
    /// observed after an arbitrary feed is phase-dependent (anywhere in `cap ... cap + slack`),
    /// so to pin the exact trim-back target we feed one line at a time and check the count the
    /// moment it *decreases* — immediately after a trim it must be exactly `cap`.
    ///
    /// This is a BEHAVIOR PIN on the exact trim-back target.
    func testHistoryCountExactlyCapAfterSettling() {
        let term = TerminalEmulator(cols: ncol, rows: nrow)
        term.maxScrollbackLines = cap
        var previous = 0
        var sawTrim = false
        for i in 0 ..< (cap + slack) * 3 {
            term.feed(line(i))
            let count = term.historyCount
            if count < previous {
                XCTAssertEqual(count, cap, "a trim must cut history back to exactly cap (\(cap))")
                sawTrim = true
            }
            previous = count
        }
        XCTAssertTrue(sawTrim, "feeding \((cap + slack) * 3) lines must trigger at least one trim")
    }

    // MARK: - (c) Oldest retained line has the expected index (no off-by-one)

    /// After feeding 300 lines into a 50-line cap (4-row viewport), the total lines
    /// ever pushed to history = 300 - 4 = 296 (the last 4 are in the viewport).
    /// With cap=50, the 50 retained lines are lines 246…295 (0-based), so the oldest
    /// retained history line is line 246.
    ///
    /// This is a BEHAVIOR PIN that catches off-by-one errors in `dropHistoryHead`.
    func testOldestRetainedLineNumber() {
        let term = buildEmulator()
        guard term.historyCount > 0 else {
            XCTFail("historyCount must be > 0 after feeding \(totalFed) lines")
            return
        }
        // Read the oldest retained snapshot (max scrollback-offset).
        let oldest = term.readGrid(scrollbackOffset: term.historyCount)
        // The oldest line is on row 0 of this snapshot.
        // captureLines starts at the oldest history; the first entry is the oldest line.
        let lines = term.captureLines(joinWrapped: false)
        // The first non-empty line should be the oldest retained.
        let firstNonEmpty = lines.first(where: { !$0.isEmpty })
        guard let first = firstNonEmpty else {
            XCTFail("captureLines returned no non-empty lines")
            return
        }
        // The text at row 0 of the max-scrollback snapshot.
        let rowText = (0 ..< ncol).compactMap { col -> String? in
            guard let cp = oldest.cell(row: 0, col: col)?.codepoint, cp != 0,
                  let scalar = Unicode.Scalar(cp) else { return nil }
            return String(scalar)
        }.joined()
        // Extract the line number from the snapshot row.
        let parts = rowText.split(separator: " ", maxSplits: 3)
        guard parts.count >= 2, let snapshotLineNum = Int(parts[1]) else {
            // The oldest row text may have trailing spaces — check captureLines instead.
            guard let capturedLineNum = lineNumber(fromCaptured: first) else {
                XCTFail("Cannot parse line number from oldest retained line: '\(first)'")
                return
            }
            // Expected: every fed line ends in \r\n, so the cursor sits on a fresh EMPTY
            // viewport row after the last feed — only nrow-1 fed lines remain in the viewport.
            // Lines pushed to history = totalFed - (nrow - 1); oldest retained = that - count.
            let expected = totalFed - (nrow - 1) - term.historyCount
            XCTAssertEqual(capturedLineNum, expected,
                           "oldest retained line should be \(expected), got \(capturedLineNum)")
            return
        }
        // See above: the trailing \r\n leaves an empty cursor row in the viewport.
        let expected = totalFed - (nrow - 1) - term.historyCount
        XCTAssertEqual(snapshotLineNum, expected,
                       "oldest retained snapshot row should be line \(expected), got \(snapshotLineNum)")
    }

    /// Cross-check: `captureLines` first non-empty entry must match `readGrid`'s oldest row.
    func testCaptureAndSnapshotAgreeOnOldestLine() {
        let term = buildEmulator()
        let lines = term.captureLines(joinWrapped: false)
        let oldest = term.readGrid(scrollbackOffset: term.historyCount)
        // Reconstruct the oldest row as a trimmed string from the snapshot.
        var rowChars: [Character] = []
        for col in 0 ..< ncol {
            guard let cp = oldest.cell(row: 0, col: col)?.codepoint, cp != 0,
                  let scalar = Unicode.Scalar(cp) else { break }
            rowChars.append(Character(scalar))
        }
        let snapRow = String(rowChars).trimmingCharacters(in: .whitespaces)
        let captureRow = lines.first(where: { !$0.isEmpty }) ?? ""
        // Both must contain the same line number.
        XCTAssertEqual(lineNumber(fromCaptured: snapRow),
                       lineNumber(fromCaptured: captureRow),
                       "snapshot oldest row and captureLines[0] must agree on line number")
    }

    // MARK: - (d) Attributes survive on the oldest retained line

    /// Each line contains " red " colored with `ESC[31m` (palette index 1).
    /// After trimming, cells on the oldest retained line that hold the word "red" must
    /// still carry `foreground == .palette(1)`.
    ///
    /// This catches bugs where trimming or ring-buffer wrap corrupts attribute data.
    func testAttributesSurviveOnOldestRetainedLine() {
        let term = buildEmulator()
        guard term.historyCount > 0 else {
            XCTFail("historyCount must be > 0")
            return
        }
        // Walk the oldest history line via bufferLine(0) (0 = oldest history line).
        // Locate the consecutive "red" run — filtering for any r/e/d codepoint would also
        // catch the UNCOLORED 'e' of the leading word "line".
        let cells = term.bufferLine(0)
        let r = UInt32(UnicodeScalar("r").value)
        let e = UInt32(UnicodeScalar("e").value)
        let d = UInt32(UnicodeScalar("d").value)
        var runStart: Int?
        for col in 0 ..< max(0, cells.count - 2)
        where cells[col].codepoint == r && cells[col + 1].codepoint == e && cells[col + 2].codepoint == d {
            runStart = col
            break
        }
        guard let start = runStart else {
            XCTFail("No 'red' run found on oldest history line — attribute test inconclusive")
            return
        }
        // All three cells forming the word "red" must carry the red foreground (palette 1).
        for cell in cells[start ... start + 2] {
            XCTAssertEqual(cell.foreground, .palette(1),
                           "cell codepoint \(cell.codepoint) of the 'red' run must have red foreground")
        }
    }

    // MARK: - (e) Wide-char head + spacerTail pairing on every retained line

    /// Every retained line contains U+5BBD (宽), a double-wide CJK character.  The
    /// leading cell must have `width == .wide`; the immediately following cell must have
    /// `width == .spacerTail`.  No spacerTail must appear at column 0 (that would be an
    /// orphaned tail from a clipped wide glyph that wasn't cleaned up).
    func testWideCharPairingOnRetainedLines() {
        let term = buildEmulator()
        let wideCodepoint: UInt32 = 0x5BBD // 宽
        // Scan all retained history lines plus viewport.
        let total = term.bufferLineCount
        for lineIdx in 0 ..< total {
            let cells = term.bufferLine(lineIdx)
            guard !cells.isEmpty else { continue }
            // Column 0 must never be a spacerTail (orphaned wide glyph tail).
            XCTAssertNotEqual(cells[0].width, .spacerTail,
                              "line \(lineIdx): col 0 must not be spacerTail (orphan)")
            // Find the wide head(s) and verify the adjacent spacerTail.
            for col in 0 ..< cells.count {
                if cells[col].codepoint == wideCodepoint {
                    XCTAssertEqual(cells[col].width, .wide,
                                   "line \(lineIdx) col \(col): 宽 must have width .wide")
                    if col + 1 < cells.count {
                        XCTAssertEqual(cells[col + 1].width, .spacerTail,
                                       "line \(lineIdx) col \(col+1): cell after 宽 must be spacerTail")
                    }
                }
            }
        }
    }

    // MARK: - (f) captureLines text matches expected line numbers

    /// `captureLines(joinWrapped: false)` returns one entry per physical line in
    /// `[history ++ viewport]`.  After 300 lines fed, the first `historyCount`
    /// non-empty entries must contain sequentially increasing line numbers.
    func testCaptureLinesHaveSequentialLineNumbers() {
        let term = buildEmulator()
        let lines = term.captureLines(joinWrapped: false)
        let nonEmpty = lines.prefix(term.historyCount).filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else {
            XCTFail("No non-empty captureLines entries in history region")
            return
        }
        var prevNum: Int? = nil
        for s in nonEmpty {
            guard let num = lineNumber(fromCaptured: s) else { continue }
            if let prev = prevNum {
                XCTAssertEqual(num, prev + 1,
                               "captureLines: expected sequential line \(prev+1), got \(num) in '\(s)'")
            }
            prevNum = num
        }
    }

    // MARK: - (g) bufferLineCount == historyCount + rows

    /// `bufferLineCount` is documented as `history.count + rows`.
    func testBufferLineCountEqualsHistoryPlusRows() {
        let term = buildEmulator()
        XCTAssertEqual(term.bufferLineCount, term.historyCount + nrow,
                       "bufferLineCount must equal historyCount + rows")
    }

    // MARK: - Interaction: resize after trim preserves invariants

    /// After trimming, a resize must not violate the cap (ScrollbackTests.testReflowAfterCapExceeded
    /// tests this already for a small feed count; this test does it for a large one with
    /// wide chars and SGR attributes).
    func testResizeAfterTrimPreservesCap() {
        let term = buildEmulator()
        let beforeHistory = term.historyCount
        term.resize(cols: ncol + 4, rows: nrow + 1)
        XCTAssertLessThanOrEqual(term.historyCount, cap,
                                 "after resize, historyCount must not exceed cap (was \(beforeHistory))")
        XCTAssertEqual(term.bufferLineCount, term.historyCount + (nrow + 1),
                       "bufferLineCount must equal historyCount + new rows after resize")
    }

    // MARK: - Zero scrollback (unlimited) is unaffected

    /// `maxScrollbackLines = 0` means unlimited — the entire feed is retained.
    /// This guards that the trim guard `if maxHistoryLines > 0` skips correctly.
    func testZeroCapIsUnlimited() {
        let term = TerminalEmulator(cols: ncol, rows: nrow)
        term.maxScrollbackLines = 0  // unlimited
        let smallFeed = cap + slack + 20
        for i in 0 ..< smallFeed { term.feed(line(i)) }
        // Every line that scrolled off must be retained. The trailing \r\n leaves an empty
        // cursor row in the viewport, so only nrow-1 fed lines are still on screen.
        let expectedHistory = smallFeed - (nrow - 1)
        XCTAssertEqual(term.historyCount, expectedHistory,
                       "unlimited scrollback must retain all \(expectedHistory) history lines")
    }

    // MARK: - Very small cap (cap=3, drives the slack=0 branch)

    /// When `maxScrollbackLines = 3`, `slack = min(1024, 3/4) = 0`.
    /// The buffer is trimmed exactly when `history.count > 3 + 0 = 3`, i.e. on overflow by 1.
    /// This exercises the `slack == 0` edge of the slack formula.
    func testVerySmallCapSlackIsZero() {
        let term = TerminalEmulator(cols: ncol, rows: nrow)
        term.maxScrollbackLines = 3
        for i in 0 ..< 20 { term.feed(line(i)) }
        XCTAssertEqual(term.historyCount, 3,
                       "cap=3 (slack=0): historyCount must settle to exactly 3")
    }
}
