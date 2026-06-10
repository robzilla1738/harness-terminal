import XCTest
@testable import HarnessTerminalEngine

final class TerminalBufferSearchTests: XCTestCase {
    /// Build buffer lines from plain strings (one cell per character).
    private func lines(_ rows: [String]) -> (Int, (Int) -> [TerminalGridCell]) {
        let cellRows: [[TerminalGridCell]] = rows.map { row in
            row.unicodeScalars.map { TerminalGridCell(codepoint: $0.value) }
        }
        return (cellRows.count, { cellRows[$0] })
    }

    func testFindsSingleMatchWithColumns() {
        let (count, line) = lines(["the quick brown fox"])
        let matches = TerminalBufferSearch.matches(query: "quick", lineCount: count, line: line)
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 4 ..< 9)])
    }

    func testCaseInsensitive() {
        let (count, line) = lines(["Hello WORLD"])
        let matches = TerminalBufferSearch.matches(query: "world", lineCount: count, line: line)
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 6 ..< 11)])
    }

    func testMultipleNonOverlappingMatchesAcrossLines() {
        let (count, line) = lines(["aa aa", "no", "aaa"])
        let matches = TerminalBufferSearch.matches(query: "aa", lineCount: count, line: line)
        XCTAssertEqual(matches, [
            TerminalBufferMatch(bufferLine: 0, columns: 0 ..< 2),
            TerminalBufferMatch(bufferLine: 0, columns: 3 ..< 5),
            TerminalBufferMatch(bufferLine: 2, columns: 0 ..< 2), // non-overlapping: only one in "aaa"
        ])
    }

    func testEmptyQueryReturnsNothing() {
        let (count, line) = lines(["anything"])
        XCTAssertTrue(TerminalBufferSearch.matches(query: "", lineCount: count, line: line).isEmpty)
    }

    func testNoMatchReturnsEmpty() {
        let (count, line) = lines(["abc", "def"])
        XCTAssertTrue(TerminalBufferSearch.matches(query: "xyz", lineCount: count, line: line).isEmpty)
    }

    func testWideCharSpacerTailDoesNotShiftColumns() {
        // A wide glyph occupies a lead cell + a spacer-tail cell; the tail maps to a space so
        // columns after it stay aligned to the grid.
        var cells: [TerminalGridCell] = [
            TerminalGridCell(codepoint: "あ".unicodeScalars.first!.value, width: .normal),
            TerminalGridCell(width: .spacerTail),
        ]
        cells += "hit".unicodeScalars.map { TerminalGridCell(codepoint: $0.value) }
        let matches = TerminalBufferSearch.matches(query: "hit", lineCount: 1, line: { _ in cells })
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 2 ..< 5)])
    }

    // MARK: - Case sensitivity

    func testCaseSensitiveSubstringRespectsCase() {
        let (count, line) = lines(["Hello WORLD"])
        let sensitive = TerminalBufferSearchOptions(isRegex: false, caseSensitive: true)
        // Lowercase query no longer matches the uppercase buffer text...
        XCTAssertTrue(TerminalBufferSearch.matches(query: "world", options: sensitive, lineCount: count, line: line).isEmpty)
        // ...but the exact-case query does.
        XCTAssertEqual(
            TerminalBufferSearch.matches(query: "WORLD", options: sensitive, lineCount: count, line: line),
            [TerminalBufferMatch(bufferLine: 0, columns: 6 ..< 11)]
        )
    }

    // MARK: - Regex

    func testRegexCharacterClassMatchesEachWord() {
        let (count, line) = lines(["the quick brown fox"])
        let regex = TerminalBufferSearchOptions(isRegex: true, caseSensitive: false)
        let matches = TerminalBufferSearch.matches(query: "[a-z]+", options: regex, lineCount: count, line: line)
        XCTAssertEqual(matches, [
            TerminalBufferMatch(bufferLine: 0, columns: 0 ..< 3),   // the
            TerminalBufferMatch(bufferLine: 0, columns: 4 ..< 9),   // quick
            TerminalBufferMatch(bufferLine: 0, columns: 10 ..< 15), // brown
            TerminalBufferMatch(bufferLine: 0, columns: 16 ..< 19), // fox
        ])
    }

    func testRegexWildcardSpansAcrossSpaces() {
        let (count, line) = lines(["the quick brown fox"])
        let regex = TerminalBufferSearchOptions(isRegex: true, caseSensitive: false)
        let matches = TerminalBufferSearch.matches(query: "quick.*fox", options: regex, lineCount: count, line: line)
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 4 ..< 19)])
    }

    func testRegexCaseSensitivity() {
        let (count, line) = lines(["Hello WORLD"])
        let sensitive = TerminalBufferSearchOptions(isRegex: true, caseSensitive: true)
        XCTAssertTrue(TerminalBufferSearch.matches(query: "world", options: sensitive, lineCount: count, line: line).isEmpty)
        XCTAssertEqual(
            TerminalBufferSearch.matches(query: "WOR.D", options: sensitive, lineCount: count, line: line),
            [TerminalBufferMatch(bufferLine: 0, columns: 6 ..< 11)]
        )
    }

    func testInvalidRegexReturnsEmpty() {
        let (count, line) = lines(["anything"])
        let regex = TerminalBufferSearchOptions(isRegex: true, caseSensitive: false)
        // An unterminated character class is an invalid pattern — no crash, no matches.
        XCTAssertTrue(TerminalBufferSearch.matches(query: "[", options: regex, lineCount: count, line: line).isEmpty)
    }

    func testRegexColumnMappingOverWideChar() {
        // The regex path renders one unit per cell, so a wide glyph's spacer tail must not shift the
        // column range it reports — mirrors `testWideCharSpacerTailDoesNotShiftColumns`.
        var cells: [TerminalGridCell] = [
            TerminalGridCell(codepoint: "あ".unicodeScalars.first!.value, width: .normal),
            TerminalGridCell(width: .spacerTail),
        ]
        cells += "hit".unicodeScalars.map { TerminalGridCell(codepoint: $0.value) }
        let regex = TerminalBufferSearchOptions(isRegex: true, caseSensitive: false)
        let matches = TerminalBufferSearch.matches(query: "h.t", options: regex, lineCount: 1, line: { _ in cells })
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 2 ..< 5)])
    }
}
