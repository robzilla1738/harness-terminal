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
}
