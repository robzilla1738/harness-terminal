import XCTest
@testable import HarnessTerminalEngine

final class GraphemeHistoryTests: XCTestCase {
    func testOversizedGeometryIsBoundedBeforeAllocation() {
        let size = TerminalGeometry.clamped(cols: .max, rows: .max)
        XCTAssertLessThanOrEqual(size.cols * size.rows, TerminalGeometry.maxCells)
        let term = TerminalEmulator(cols: .max, rows: 1)
        XCTAssertEqual(term.cols, TerminalGeometry.maxDimension)
        term.resize(cols: 1, rows: .max)
        XCTAssertEqual(term.rows, TerminalGeometry.maxDimension)
        XCTAssertFalse(TerminalGeometry.isValid(cols: 65_535, rows: 65_535))
    }

    func testCompoundEmojiAndDeepCombiningSurviveEveryReadPath() {
        for text in ["👨‍👩‍👧‍👦", "👩🏽‍💻", "🇺🇸", "❤️", "1️⃣", "a\u{301}\u{323}\u{302}\u{304}"] {
            let term = TerminalEmulator(cols: 12, rows: 3)
            let reference = TerminalEmulator(cols: 12, rows: 3)
            term.feed(text + "X")
            reference.feedScalarwise(Array((text + "X").utf8))
            XCTAssertEqual(term.readGrid(), reference.readGrid(), text)
            XCTAssertEqual(term.captureLines(joinWrapped: true).first, text + "X", text)
            let width = text.unicodeScalars.first?.value == 97 ? 1 : 2
            XCTAssertEqual(term.readGrid().cursor.col, width + 1, text)
            XCTAssertEqual(term.cluster(for: term.readGrid().cells[0]), text)
            let retained = term.readGrid()
            term.resize(cols: 5, rows: 3)
            XCTAssertEqual(term.captureLines(joinWrapped: true).first, text + "X", text)
            let restored = TerminalEmulator(cols: 5, rows: 3)
            restored.feed(PaneCapture.screen(term))
            XCTAssertEqual(restored.captureLines(joinWrapped: true).first, text + "X", text)
            term.feed("\u{1b}c")
            XCTAssertEqual(retained.cells[0].resolvedCluster(in: retained.clusters), text)
        }
    }

    func testDecodedBudgetAccountsForRetainedWidthsAfterResizeAndClear() {
        let term = TerminalEmulator(cols: 200, rows: 2)
        term.maxScrollbackLines = 0
        term.maxDecodedHistoryBytes = 32_000
        term.feed(String(repeating: String(repeating: "x", count: 190) + "\r\n", count: 100))
        XCTAssertLessThanOrEqual(term.decodedHistoryBytes, 32_000)
        XCTAssertLessThan(term.historyCount, 10)
        term.resize(cols: 40, rows: 2)
        XCTAssertLessThanOrEqual(term.decodedHistoryBytes, 32_000)
        term.feed("\u{1b}[3J")
        XCTAssertEqual(term.historyCount, 0)
        XCTAssertEqual(term.decodedHistoryBytes, 0)
    }

    func testSearchMapsWideTextAndSoftWrapsAndReportsInvalidPattern() {
        let term = TerminalEmulator(cols: 4, rows: 3)
        term.feed("中文ab👩🏽‍💻")
        let snapshot = term.textSnapshot()
        let outcome = TerminalBufferSearch.search(query: "文ab", lineCount: snapshot.lineCount,
            clusters: snapshot.clusters, isWrapped: snapshot.isWrapped, line: snapshot.line)
        XCTAssertEqual(outcome, .matches([TerminalBufferMatch(spans: [
            TerminalBufferSpan(bufferLine: 0, columns: 2..<4),
            TerminalBufferSpan(bufferLine: 1, columns: 0..<2)
        ])], limited: false))
        XCTAssertEqual(TerminalBufferSearch.matches(query: "👩🏽‍💻", options: .default,
            lineCount: snapshot.lineCount, clusters: snapshot.clusters, line: snapshot.line).first?.columns, 2..<4)
        guard case .invalidPattern = TerminalBufferSearch.search(query: "[", options: .init(isRegex: true),
            lineCount: snapshot.lineCount, line: snapshot.line) else { return XCTFail("invalid regex must be explicit") }
        XCTAssertEqual(TerminalBufferSearch.search(query: "文", lineCount: snapshot.lineCount,
            cancelled: { true }, line: snapshot.line), .cancelled)
    }
}
