import Foundation
@testable import HarnessTerminalKit
import XCTest

@MainActor
final class HarnessTerminalSurfaceWorkerTests: XCTestCase {
    private func configure(_ view: HarnessTerminalSurfaceView, offMain: Bool) {
        view.configureAppearance(
            fontFamily: "Menlo",
            fontSize: 14,
            vivid: false,
            colorRendering: .accurate,
            colorGamut: .auto,
            canvasBackgroundHex: "#000000",
            canvasForegroundHex: "#ffffff",
            cursorHex: "#ffffff",
            outputPaletteHex: Array(repeating: nil, count: 16),
            canvasOpacity: 1,
            cursorStyle: "block",
            cursorBlink: true,
            paddingX: 0,
            paddingY: 0,
            selectionBackgroundHex: nil,
            selectionForegroundHex: nil,
            copyOnSelect: false,
            scrollbackLines: 10_000,
            linearBlending: false,
            textRendering: .native,
            ligatures: true,
            promptGutter: false,
            offMainParserFramePipeline: offMain
        )
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    func testOffMainDSRResponseIsDeliveredAfterVisibleOutput() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        let response = expectation(description: "DSR response")
        view.onInput = { data in
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\u{1b}[1;2R")
            let grid = view.testingReadGridSnapshot()
            XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, Unicode.Scalar("A").value)
            response.fulfill()
        }

        view.receive("A\u{1b}[6n")

        await fulfillment(of: [response], timeout: 2)
    }

    func testOffMainSynchronizedOutputHoldsAndReleasesRender() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)

        view.receive("\u{1b}[?2026hpartial")
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
        XCTAssertTrue(view.testingRenderSynchronized)

        view.receive(" final\u{1b}[?2026l")
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
        XCTAssertFalse(view.testingRenderSynchronized)
        XCTAssertTrue(view.testingRenderPending)

        let grid = view.testingReadGridSnapshot()
        let text = (0 ..< 13).compactMap { col -> String? in
            guard let codepoint = grid.cell(row: 0, col: col)?.codepoint,
                  let scalar = Unicode.Scalar(codepoint),
                  codepoint != 0
            else { return nil }
            return String(scalar)
        }.joined()
        XCTAssertEqual(text, "partial final")
    }

    func testOffMainResizeSerializesWithHeavyOutput() {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        let line = "resize worker stress 0123456789\r\n"
        let data = Data(String(repeating: line, count: 2_000).utf8)

        view.receive(data)
        view.testingResizeGrid(cols: 100, rows: 30)
        view.testingWaitForEmulatorIdle()

        let grid = view.testingReadGridSnapshot()
        XCTAssertEqual(grid.cols, 100)
        XCTAssertEqual(grid.rows, 30)
    }

    func testInputModesMirrorTracksModeChangesAcrossMainHop() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        XCTAssertFalse(view.testingInputModes().cursorKeysApplication)
        XCTAssertEqual(view.testingInputModes().kittyKeyboardFlags, 0)

        // The shape fish 4.x sets at its prompt: DECCKM + Kitty flags 5 in one chunk. The input
        // paths read a main-thread mirror (no queue.sync against the parser); it must reflect the
        // change once the chunk's main hop lands.
        view.receive("\u{1b}[?1h\u{1b}[=5u")
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
        XCTAssertTrue(view.testingInputModes().cursorKeysApplication)
        XCTAssertEqual(view.testingInputModes().kittyKeyboardFlags, 5)

        view.receive("\u{1b}[?1l\u{1b}[=0u")
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
        XCTAssertFalse(view.testingInputModes().cursorKeysApplication)
        XCTAssertEqual(view.testingInputModes().kittyKeyboardFlags, 0)
    }

    func testOffMainPipelineCanBeDisabledWithoutRacingQueuedWork() {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        view.receive("A")
        view.testingWaitForEmulatorIdle()

        configure(view, offMain: false)
        view.receive("B")

        let grid = view.testingReadGridSnapshot()
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.codepoint, Unicode.Scalar("A").value)
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.codepoint, Unicode.Scalar("B").value)
    }
}
