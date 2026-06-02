import XCTest
@testable import HarnessTerminalEngine

/// The printable-ASCII run fast path must be byte-for-byte equivalent to printing one scalar at a
/// time. Each test feeds the same bytes two ways — `feed` (run-batched) vs `feedScalarwise`
/// (per-byte scalar path) — and asserts the resulting screens are identical.
final class AsciiFastPathTests: XCTestCase {
    /// Feed `input` via the run path and the scalar path into fresh emulators and assert their
    /// full state matches (live snapshot, scrollback snapshot, history, and capture).
    private func assertRunMatchesScalar(
        _ input: String,
        cols: Int = 20,
        rows: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bytes = Array(input.utf8)

        let run = TerminalEmulator(cols: cols, rows: rows)
        run.feed(bytes)

        let scalar = TerminalEmulator(cols: cols, rows: rows)
        scalar.feedScalarwise(bytes)

        XCTAssertEqual(run.readGrid(), scalar.readGrid(), "live snapshot differs", file: file, line: line)
        XCTAssertEqual(run.historyCount, scalar.historyCount, "history count differs", file: file, line: line)
        XCTAssertEqual(
            run.readGrid(scrollbackOffset: run.historyCount).cells,
            scalar.readGrid(scrollbackOffset: scalar.historyCount).cells,
            "scrollback snapshot differs", file: file, line: line
        )
        XCTAssertEqual(
            run.captureLines(joinWrapped: false), scalar.captureLines(joinWrapped: false),
            "capture differs", file: file, line: line
        )
    }

    func testSimpleLine() {
        assertRunMatchesScalar("the quick brown fox")
    }

    func testWrapAtRightMargin() {
        // Longer than one row at width 20 → soft-wraps across rows.
        assertRunMatchesScalar("0123456789abcdefghijABCDEFGHIJ0123456789", cols: 20, rows: 6)
    }

    func testAutowrapDisabled() {
        // DECAWM off: the tail of an over-long line pins at the last column.
        assertRunMatchesScalar("\u{1b}[?7l0123456789abcdefghijKLMNOP", cols: 20, rows: 6)
    }

    func testNewlinesAndCarriageReturnsMixedWithText() {
        assertRunMatchesScalar("alpha\r\nbeta\r\ngamma\rXY\r\ndelta")
    }

    func testSGRBeforeAndAfterText() {
        assertRunMatchesScalar("\u{1b}[1;31mRED bold\u{1b}[0m then \u{1b}[4munder\u{1b}[0m plain")
    }

    func testScrollAtBottom() {
        // More lines than rows → scrolling, exercising the wrap→lineFeed→scrollUp path in a run.
        var s = ""
        for i in 0 ..< 30 { s += "line number \(i)\r\n" }
        assertRunMatchesScalar(s, cols: 16, rows: 4)
    }

    func testTrailingArmedWrapBoundary() {
        // Exactly fills a row (arms pendingWrap) with no following byte, then more input later.
        assertRunMatchesScalar("01234567890123456789", cols: 20, rows: 4) // exactly one row
        assertRunMatchesScalar("01234567890123456789Z", cols: 20, rows: 4) // one row + 1 (wraps)
    }

    func testSingleColumnTerminal() {
        assertRunMatchesScalar("abcdef", cols: 1, rows: 4)
        assertRunMatchesScalar("\u{1b}[?7labcdef", cols: 1, rows: 4) // autowrap off, width 1
    }

    func testMixedUnicodeAndControlsStayEquivalent() {
        // ASCII runs interleaved with multibyte UTF-8, wide chars, a combining mark, and a tab.
        assertRunMatchesScalar("ab café — 日本語\tx\u{0301}y end", cols: 24, rows: 5)
    }

    /// Splitting the same bytes across `feed` calls at arbitrary offsets (including mid-run) must
    /// produce the same screen as one bulk feed — proves run-boundary handling across calls.
    func testBulkVersusChunkedFeedIsIdentical() {
        let input = "\u{1b}[32mhello\u{1b}[0m world 0123456789 the quick brown fox jumps\r\nsecond line here"
        let bytes = Array(input.utf8)

        let bulk = TerminalEmulator(cols: 18, rows: 5)
        bulk.feed(bytes)

        for chunk in [1, 2, 3, 5, 7, 13] {
            let chunked = TerminalEmulator(cols: 18, rows: 5)
            var i = 0
            while i < bytes.count {
                let end = min(bytes.count, i + chunk)
                chunked.feed(Array(bytes[i ..< end]))
                i = end
            }
            XCTAssertEqual(bulk.readGrid(), chunked.readGrid(), "chunk size \(chunk) differs")
        }
    }

    /// The SIMD16 run scanner processes 16-byte chunks then a scalar tail. Place a run-stopping
    /// byte (a control, ESC, DEL, and a high UTF-8 lead) at every offset across two SIMD strides so
    /// the boundary is exercised inside a chunk, exactly on a chunk edge, and in the tail — each must
    /// match the per-byte scalar path.
    func testSIMDRunBoundaryAtEveryOffset() {
        for stop in ["\n", "\u{1b}[m", "\u{7f}", "é"] {
            for offset in 0 ..< 40 {
                let input = String(repeating: "x", count: offset) + stop
                    + String(repeating: "y", count: 40 - offset)
                assertRunMatchesScalar(input, cols: 24, rows: 6, line: UInt(offset))
            }
        }
    }

    func testDECSpecialGraphicsRunStillDrawsLines() {
        // `ESC ( 0` selects line drawing; lqqk should map to box glyphs even via the run path.
        let run = TerminalEmulator(cols: 20, rows: 3)
        run.feed("\u{1b}(0lqqk\u{1b}(B")
        let scalar = TerminalEmulator(cols: 20, rows: 3)
        scalar.feedScalarwise(Array("\u{1b}(0lqqk\u{1b}(B".utf8))
        XCTAssertEqual(run.readGrid(), scalar.readGrid())
        // 'l' → U+250C (┌), not the literal ASCII 'l'.
        XCTAssertEqual(run.readGrid().cell(row: 0, col: 0)?.codepoint, 0x250C)
    }
}
