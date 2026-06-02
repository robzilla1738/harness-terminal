import XCTest
@testable import HarnessTerminalEngine

/// The bulk codepoint run path (ASCII + well-formed UTF-8 decoded in one pass and emitted via
/// `parserPrintCodepointRun`) must be byte-for-byte equivalent to decoding/printing one scalar at a
/// time. `feed` drives the bulk path; `feedScalarwise` drives the per-byte scalar path. Every case
/// also feeds the same bytes split at adversarial chunk sizes, since a multibyte sequence (or a
/// malformed one) can straddle a `feed` boundary — that carry-over must match too.
final class CodepointRunFastPathTests: XCTestCase {
    /// Assert the bulk `feed`, the scalar `feedScalarwise`, and several chunked `feed` splits all
    /// land on the same screen state (live grid, history, scrollback, capture).
    private func assertAllPathsAgree(
        _ bytes: [UInt8],
        cols: Int = 20,
        rows: Int = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scalar = TerminalEmulator(cols: cols, rows: rows)
        scalar.feedScalarwise(bytes)

        func assertMatches(_ term: TerminalEmulator, _ label: String) {
            XCTAssertEqual(term.readGrid(), scalar.readGrid(), "\(label): live snapshot differs", file: file, line: line)
            XCTAssertEqual(term.historyCount, scalar.historyCount, "\(label): history count differs", file: file, line: line)
            XCTAssertEqual(
                term.readGrid(scrollbackOffset: term.historyCount).cells,
                scalar.readGrid(scrollbackOffset: scalar.historyCount).cells,
                "\(label): scrollback differs", file: file, line: line
            )
            XCTAssertEqual(
                term.captureLines(joinWrapped: false), scalar.captureLines(joinWrapped: false),
                "\(label): capture differs", file: file, line: line
            )
        }

        let bulk = TerminalEmulator(cols: cols, rows: rows)
        bulk.feed(bytes)
        assertMatches(bulk, "bulk")

        // Adversarial chunk sizes — small primes force multibyte/malformed sequences to straddle
        // feed boundaries, exercising the cross-call UTF-8 carry-over.
        for chunk in [1, 2, 3, 4, 5, 7, 11, 13] {
            let chunked = TerminalEmulator(cols: cols, rows: rows)
            var i = 0
            while i < bytes.count {
                let end = min(bytes.count, i + chunk)
                chunked.feed(Array(bytes[i ..< end]))
                i = end
            }
            assertMatches(chunked, "chunk=\(chunk)")
        }
    }

    private func assertAllPathsAgree(
        _ s: String, cols: Int = 20, rows: Int = 6, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertAllPathsAgree(Array(s.utf8), cols: cols, rows: rows, file: file, line: line)
    }

    // MARK: - Well-formed text

    func testMixedWidthUnicode() {
        assertAllPathsAgree("café résumé Ω 世 Ж 中 λ ✓ 漢字 naïve", cols: 24, rows: 6)
    }

    func testLeadingHighByteThenASCII() {
        // The bulk path triggers on a >= 0x80 lead and must also sweep the trailing ASCII in the run.
        assertAllPathsAgree("日本語abcdef0123 mixed トン", cols: 16, rows: 5)
    }

    func testWideGlyphsWrapAndSpacerTail() {
        // Wide CJK at the right margin must wrap (and lay a spacerTail) exactly as the scalar path.
        assertAllPathsAgree("aaa世界世界世界世界世界世界", cols: 10, rows: 6)
        assertAllPathsAgree(String(repeating: "中", count: 40), cols: 7, rows: 5)
    }

    func testCombiningMarksAreZeroWidth() {
        // Combining acute (U+0301) attaches to the previous cell and never advances the cursor.
        assertAllPathsAgree("e\u{0301}a\u{0301}o\u{0301} cafe\u{0301}", cols: 12, rows: 4)
    }

    func testEmojiAndSupplementaryPlane() {
        assertAllPathsAgree("hi 🙂 ok 😀😀 𝛀 𐍈 end", cols: 18, rows: 5)
    }

    func testAutowrapDisabledWithUnicode() {
        assertAllPathsAgree("\u{1b}[?7l日本語abcdefghij KL", cols: 10, rows: 4)
    }

    func testUnicodeInterleavedWithSGRAndControls() {
        assertAllPathsAgree("\u{1b}[31m世界\u{1b}[0m abc\r\n中文\tx café\r\n", cols: 16, rows: 5)
    }

    func testScrollingWithUnicode() {
        var s = ""
        for i in 0 ..< 30 { s += "行 \(i) 世界 résumé\r\n" }
        assertAllPathsAgree(s, cols: 14, rows: 4)
    }

    func testSingleColumnWithWideGlyph() {
        // A width-2 glyph in a 1-column terminal — degenerate wrap/clamp must match.
        assertAllPathsAgree("a中b世c", cols: 1, rows: 4)
    }

    // MARK: - Malformed UTF-8 (must defer to the scalar path's U+FFFD / reprocess semantics)

    func testInvalidLeadByte() {
        // 0xFF and 0xC0/0xC1 region / stray bytes are not valid leads → U+FFFD, consume one byte.
        assertAllPathsAgree([0x61, 0xFF, 0x62, 0xC0, 0x63], cols: 12, rows: 4) // a ? b ? c
    }

    func testLoneContinuationBytes() {
        assertAllPathsAgree([0x80, 0x81, 0xBF, 0x61, 0x80, 0x62], cols: 12, rows: 4)
    }

    func testTruncatedSequenceAtEnd() {
        // 3-byte lead with only the lead present (chunk/stream boundary mid-sequence).
        assertAllPathsAgree([0x61, 0xE4, 0xB8], cols: 12, rows: 4)       // 'a' + truncated 中
        assertAllPathsAgree([0x61, 0xF0, 0x9F, 0x99], cols: 12, rows: 4) // 'a' + truncated 🙂
    }

    func testOverlongEncodings() {
        // Overlong '/' (0xC0 0xAF) and overlong NUL (0xC0 0x80) must each yield U+FFFD, not the char.
        assertAllPathsAgree([0x61, 0xC0, 0xAF, 0x62], cols: 12, rows: 4)
        assertAllPathsAgree([0x61, 0xE0, 0x80, 0xAF, 0x62], cols: 12, rows: 4)
    }

    func testSurrogateAndOutOfRange() {
        // CESU-8-style surrogate (U+D800 as 0xED 0xA0 0x80) and > U+10FFFF (0xF4 0x90 0x80 0x80).
        assertAllPathsAgree([0x61, 0xED, 0xA0, 0x80, 0x62], cols: 12, rows: 4)
        assertAllPathsAgree([0x61, 0xF4, 0x90, 0x80, 0x80, 0x62], cols: 12, rows: 4)
    }

    func testInvalidContinuationMidSequence() {
        // 3-byte lead, valid first continuation, then an ASCII byte where a continuation is expected.
        assertAllPathsAgree([0xE4, 0xB8, 0x41, 0x42], cols: 12, rows: 4)
    }

    func testHighByteRunsThenAnomalyThenText() {
        assertAllPathsAgree([0xE4, 0xB8, 0xAD, 0xFF, 0xE6, 0x96, 0x87, 0x21], cols: 12, rows: 4) // 中 ? 文 !
    }
}
