import XCTest
@testable import HarnessTerminalEngine

/// `maxScrollbackLines == 0` means **unlimited** (tmux/ghostty convention), mapped to a bounded
/// OOM-safe ceiling — not a literal zero-line scrollback. A positive value caps exactly.
final class UnlimitedScrollbackTests: XCTestCase {
    private func feedLines(_ term: TerminalEmulator, _ n: Int) {
        for i in 0 ..< n { term.feed("L\(i)\r\n") }
    }

    func testZeroMeansUnlimitedNotZero() {
        let term = TerminalEmulator(cols: 12, rows: 2)
        term.maxScrollbackLines = 0
        XCTAssertEqual(term.maxScrollbackLines, TerminalEmulator.unlimitedScrollbackLines,
                       "0 maps to the unlimited ceiling, not literal 0")
        feedLines(term, 500)
        XCTAssertGreaterThanOrEqual(term.historyCount, 400,
                                    "unlimited scrollback retains far more than a small cap would")
    }

    func testPositiveCapTrimsHistory() {
        let term = TerminalEmulator(cols: 12, rows: 2)
        term.maxScrollbackLines = 50
        XCTAssertEqual(term.maxScrollbackLines, 50)
        feedLines(term, 500)
        XCTAssertLessThanOrEqual(term.historyCount, 120, "a positive cap trims history toward that many lines")
        XCTAssertGreaterThanOrEqual(term.historyCount, 50, "and keeps roughly the cap's worth")
    }

    func testNegativeIsClampedToUnlimited() {
        let term = TerminalEmulator(cols: 12, rows: 2)
        term.maxScrollbackLines = -1
        XCTAssertEqual(term.maxScrollbackLines, TerminalEmulator.unlimitedScrollbackLines)
    }
}
