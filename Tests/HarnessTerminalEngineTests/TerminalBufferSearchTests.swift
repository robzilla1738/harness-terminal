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

    // MARK: - Case sensitivity (roadmap PR-21)

    func testCaseSensitiveSubstringRespectsCase() {
        let (count, line) = lines(["Hello WORLD"])
        XCTAssertTrue(TerminalBufferSearch.matches(query: "world", lineCount: count, caseSensitive: true, line: line).isEmpty)
        XCTAssertEqual(TerminalBufferSearch.matches(query: "WORLD", lineCount: count, caseSensitive: true, line: line),
                       [TerminalBufferMatch(bufferLine: 0, columns: 6 ..< 11)])
    }

    // MARK: - Regex (roadmap PR-21)

    func testRegexMatchesWithColumns() {
        let (count, line) = lines(["the quick brown fox"])
        let matches = TerminalBufferSearch.matches(query: "qu\\w+", lineCount: count, regex: true, line: line)
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 4 ..< 9)])
    }

    func testRegexIsCaseInsensitiveByDefaultButCaseSensitiveWhenAsked() {
        let (count, line) = lines(["Hello WORLD"])
        XCTAssertEqual(TerminalBufferSearch.matches(query: "world", lineCount: count, regex: true, line: line),
                       [TerminalBufferMatch(bufferLine: 0, columns: 6 ..< 11)])
        XCTAssertTrue(TerminalBufferSearch.matches(query: "world", lineCount: count, caseSensitive: true, regex: true, line: line).isEmpty)
    }

    func testRegexAnchorsAndClasses() {
        let (count, line) = lines(["error: code 42", "ok: code 7"])
        let matches = TerminalBufferSearch.matches(query: "^error", lineCount: count, regex: true, line: line)
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 0 ..< 5)])
        let digits = TerminalBufferSearch.matches(query: "\\d+", lineCount: count, regex: true, line: line)
        XCTAssertEqual(digits, [
            TerminalBufferMatch(bufferLine: 0, columns: 12 ..< 14),
            TerminalBufferMatch(bufferLine: 1, columns: 9 ..< 10),
        ])
    }

    func testInvalidRegexReturnsEmptyInsteadOfThrowing() {
        let (count, line) = lines(["anything ["])
        XCTAssertTrue(TerminalBufferSearch.matches(query: "[", lineCount: count, regex: true, line: line).isEmpty)
    }

    func testRegexZeroWidthMatchesAreSkipped() {
        let (count, line) = lines(["abc"])
        // `x*` matches empty everywhere; none should be reported as a (zero-width) hit.
        XCTAssertTrue(TerminalBufferSearch.matches(query: "x*", lineCount: count, regex: true, line: line).isEmpty)
    }

    func testRegexColumnsAccountForWideCharSpacerTail() {
        var cells: [TerminalGridCell] = [
            TerminalGridCell(codepoint: "あ".unicodeScalars.first!.value, width: .normal),
            TerminalGridCell(width: .spacerTail),
        ]
        cells += "hit".unicodeScalars.map { TerminalGridCell(codepoint: $0.value) }
        let matches = TerminalBufferSearch.matches(query: "h.t", lineCount: 1, regex: true, line: { _ in cells })
        XCTAssertEqual(matches, [TerminalBufferMatch(bufferLine: 0, columns: 2 ..< 5)])
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
}
