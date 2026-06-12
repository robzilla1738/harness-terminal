import Foundation
import XCTest
@testable import HarnessTerminalKit

/// #168 at the kit layer: `receive(_:replay:)` must bracket exactly the replayed chunk's feed
/// with `isReplaying` on the emulator's serialized context, in BOTH pipelines — replayed
/// queries emit nothing on `onInput`, while live queries before and after keep answering.
@MainActor
final class ReplayReceiveTests: XCTestCase {
    private static let query = "\u{1b}[?2026$p\u{1b}[?u\u{1b}[6n" // DECRQM + kitty + DSR

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func runSuppressionCheck(offMain: Bool) async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: offMain)
        var emitted: [String] = []
        view.onInput = { emitted.append(String(decoding: $0, as: UTF8.self)) }

        view.receive("history line\r\n" + Self.query + "more history\r\n", replay: true)
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
        XCTAssertTrue(emitted.isEmpty, "replayed queries leaked to the PTY (offMain=\(offMain)): \(emitted)")

        view.receive(Self.query)
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
        XCTAssertFalse(emitted.isEmpty, "live queries must answer after a replay (offMain=\(offMain))")

        // The replayed content itself must have landed.
        let grid = view.testingReadGridSnapshot()
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, Unicode.Scalar("h").value)
    }

    func testReplayReceiveSuppressesQueriesSyncPipeline() async {
        await runSuppressionCheck(offMain: false)
    }

    func testReplayReceiveSuppressesQueriesOffMainPipeline() async {
        await runSuppressionCheck(offMain: true)
    }
}
