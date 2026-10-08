import Foundation
import HarnessTerminalEngine
import XCTest
@testable import HarnessTerminalKit

/// A resync paints the daemon's screen at once and rebuilds the scrollback behind it: after the
/// swap the pane is what a full replay gives, live output during the restore is neither lost
/// nor doubled, queries answer once, and a selection stays on its text. Both pipelines.
@MainActor
final class HistoryRestoreTests: XCTestCase {
    private func settle(_ view: HarnessTerminalSurfaceView) async {
        for _ in 0 ..< 500 {
            view.testingWaitForEmulatorIdle()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            if !view.testingHistoryRestorePending { break }
        }
        view.testingWaitForEmulatorIdle()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func runRestore(offMain: Bool) async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: offMain)
        let (cols, rows) = view.testingGridSize
        var titles: [String] = []
        var responses: [String] = []
        view.onTitle = { titles.append($0) }
        view.onInput = { responses.append(String(decoding: $0, as: UTF8.self)) }

        let history = Data(((0 ..< 300).map { "history \($0)\r\n" }.joined() + "\u{1b}]2;restored\u{07}\u{1b}[6n$ ").utf8)
        let live = Data("live\r\n\u{1b}[6n".utf8)
        let truth = TerminalEmulator(cols: cols, rows: rows)
        truth.feed(history)
        let screen = PaneCapture.screen(truth)
        truth.feed(live)

        view.beginHistoryRestore(screen: screen)
        await settle(view)
        XCTAssertTrue(view.testingHistoryRestorePending)
        XCTAssertEqual(view.accessibilitySnapshot().lines.count, rows, "the screen paints with no history parsed")
        XCTAssertTrue(view.accessibilitySnapshot().lines.contains { $0.hasPrefix("history 299") })
        view.testingSetSelection(anchor: (row: rows - 2, column: 0), head: (row: rows - 2, column: 10))
        let selected = view.testingSelectionText()

        view.receiveHistory(history)
        view.receive(live)
        view.finishHistoryRestore()
        await settle(view)

        XCTAssertFalse(view.testingHistoryRestorePending)
        let restored = view.accessibilitySnapshot()
        XCTAssertEqual(restored.lines, truth.captureLines(joinWrapped: false), "history, screen, and live output, once each")
        XCTAssertEqual(restored.cursorLine, truth.historyCount + truth.readGrid().cursor.row)
        XCTAssertEqual(responses.count, 1, "the live query answers once; the history's never does (offMain=\(offMain))")
        XCTAssertTrue(responses.first?.hasSuffix("R") == true)
        XCTAssertEqual(titles, ["restored"], "the restored title reaches the host at the swap")
        XCTAssertEqual(view.testingSelectionText(), selected, "a selection stays on its text")

        view.receive("after\r\n")
        await settle(view)
        XCTAssertTrue(view.accessibilitySnapshot().lines.contains { $0.hasPrefix("after") }, "output goes to the swapped-in emulator")
    }

    func testRestoreSwapsInTheHistorySyncPipeline() async {
        await runRestore(offMain: false)
    }

    func testRestoreSwapsInTheHistoryOffMainPipeline() async {
        await runRestore(offMain: true)
    }

    func testARestoreWithNoHistoryKeepsTheScreen() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.beginHistoryRestore(screen: Data("\u{1b}[H\u{1b}[2Jonly the screen".utf8))
        view.finishHistoryRestore()
        await settle(view)
        XCTAssertFalse(view.testingHistoryRestorePending)
        XCTAssertTrue(view.accessibilitySnapshot().lines.first?.hasPrefix("only the screen") == true)
    }
}
