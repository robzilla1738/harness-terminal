import XCTest
@testable import HarnessTerminalEngine

/// `TerminalEmulator.logicalLineRowSpan` drives triple-click logical-line selection: it joins the
/// physical rows of a soft-wrapped line into one span. Virtual-line space is `[history ++ viewport]`.
final class LogicalLineSpanTests: XCTestCase {
    func testUnwrappedLineSpansItself() {
        let term = TerminalEmulator(cols: 10, rows: 4)
        term.feed("AB\r\nCD")
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: 0), 0 ... 0)
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: 1), 1 ... 1)
    }

    func testTwoRowWrapJoins() {
        let term = TerminalEmulator(cols: 10, rows: 4)
        // 20 printable chars at width 10 fill row 0 and soft-wrap onto row 1 — one logical line.
        term.feed("0123456789ABCDEFGHIJ")
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: 0), 0 ... 1, "row 0 is the head of the wrapped line")
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: 1), 0 ... 1, "row 1 is the tail of the same logical line")
    }

    func testThreeRowWrapJoinsFromAnyRow() {
        let term = TerminalEmulator(cols: 5, rows: 6)
        // 12 chars at width 5 → rows 0,1 wrap, row 2 is the tail.
        term.feed("0123456789AB")
        for row in 0 ... 2 {
            XCTAssertEqual(term.logicalLineRowSpan(virtualLine: row), 0 ... 2,
                           "every row of the 3-row wrapped line resolves to the full span")
        }
    }

    func testWrappedLineFollowedByHardLineDoesNotOverreach() {
        let term = TerminalEmulator(cols: 5, rows: 6)
        // First logical line wraps rows 0–1; a hard newline starts a separate line on row 2.
        term.feed("0123456789\r\nX")
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: 0), 0 ... 1)
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: 1), 0 ... 1)
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: 2), 2 ... 2, "the hard-newline line is its own span")
    }

    func testOutOfRangeVirtualLineClampsInsteadOfCrashing() {
        let term = TerminalEmulator(cols: 8, rows: 3)
        term.feed("hi")
        // Negative and past-the-end indices clamp into the addressable range.
        XCTAssertEqual(term.logicalLineRowSpan(virtualLine: -5).lowerBound, 0)
        let last = term.logicalLineRowSpan(virtualLine: 999)
        XCTAssertLessThanOrEqual(last.upperBound, term.historyCount + 2)
    }
}
