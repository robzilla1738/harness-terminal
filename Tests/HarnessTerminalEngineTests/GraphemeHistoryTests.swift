import XCTest
@testable import HarnessTerminalEngine

final class GraphemeHistoryTests: XCTestCase {
    func testNewUnicodeCombiningMarksSurviveWithoutHostUnicodeSupport() {
        let text = "A\u{05C8}\u{1ACF}\u{1AE0}\u{0897}"
        let term = TerminalEmulator(cols: 8, rows: 2)
        let scalarwise = TerminalEmulator(cols: 8, rows: 2)
        term.feed(text + "X")
        scalarwise.feedScalarwise(Array((text + "X").utf8))
        XCTAssertEqual(term.readGrid(), scalarwise.readGrid())
        XCTAssertEqual(term.readGrid().cursor.col, 2)
        XCTAssertEqual(term.cluster(for: term.readGrid().cells[0]), text)
        XCTAssertEqual(term.captureLines(joinWrapped: true).first, text + "X")
        term.resize(cols: 3, rows: 2)
        XCTAssertEqual(term.captureLines(joinWrapped: true).first, text + "X")
        let restored = TerminalEmulator(cols: 3, rows: 2)
        restored.feed(PaneCapture.screen(term))
        XCTAssertEqual(restored.captureLines(joinWrapped: true).first, text + "X")
    }

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
        XCTAssertLessThan(term.historyCount, 100)
        term.resize(cols: 40, rows: 2)
        XCTAssertLessThanOrEqual(term.decodedHistoryBytes, 32_000)
        term.feed("\u{1b}[3J")
        XCTAssertEqual(term.historyCount, 0)
        XCTAssertEqual(term.decodedHistoryBytes, 0)
    }

    func testCompactHistoryPreservesAllCellAttributesAndSnapshotOwnership() {
        let payloads = [
            "plain text with spaces  ",
            "\u{1b}[1;3;4;38;2;12;34;56mcolored text\u{1b}[0m",
            "\u{1b}[44m\u{1b}[2K\u{1b}[0mstyled blank padding",
            "中文 👩🏽‍💻 a\u{301} end",
            "\u{1b}]8;;https://example.com\u{7}linked\u{1b}]8;;\u{7} plain",
        ]
        for payload in payloads {
            let term = TerminalEmulator(cols: 50, rows: 2)
            term.feed(payload)
            let expected = Array(term.readGrid().cells.prefix(50))
            let snapshot = term.textSnapshot()
            term.feed("\r\n\r\n\r\n")
            XCTAssertEqual(term.bufferLine(0), expected, payload)
            XCTAssertEqual(snapshot.line(0), expected, payload)
            term.resize(cols: 50, rows: 5)
            XCTAssertEqual(term.bufferLine(0), expected, payload)
        }
    }

    func testShortHistoryRowsDoNotRetainFullWidthCellArrays() {
        let term = TerminalEmulator(cols: 150, rows: 3)
        term.maxScrollbackLines = 0
        for index in 0..<1_000 { term.feed("history row \(index)\r\n") }
        XCTAssertGreaterThan(term.historyCount, 990)
        XCTAssertLessThan(term.decodedHistoryBytes, 512 * 1024)
        XCTAssertEqual(term.captureLines(joinWrapped: true).first, "history row 0")
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
