import Foundation
import XCTest
@testable import HarnessTerminalKit

/// `select-last-output`: select the lines strictly between the last two OSC 133 prompt marks.
@MainActor
final class SelectLastCommandOutputTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func settle(_ view: HarnessTerminalSurfaceView) async {
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
    }

    func testSelectsTheLastFinishedCommandsOutput() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.receive("\u{1b}]133;A\u{07}$ make test\r\n")
        view.receive("building things\r\nall tests green\r\n")
        view.receive("\u{1b}]133;A\u{07}$ ")
        await settle(view)

        view.selectLastCommandOutput()
        XCTAssertEqual(view.testingSelectionText(), "building things\nall tests green")
    }

    func testNoOpWithoutTwoPromptMarks() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.receive("no shell integration here\r\n")
        await settle(view)
        view.selectLastCommandOutput()
        XCTAssertNil(view.testingSelectionText())

        view.receive("\u{1b}]133;A\u{07}$ ")
        await settle(view)
        view.selectLastCommandOutput() // one mark only — still nothing bracketed
        XCTAssertNil(view.testingSelectionText())
    }

    func testNoOpWhenTheCommandPrintedNothing() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.receive("\u{1b}]133;A\u{07}$ true\r\n")
        view.receive("\u{1b}]133;A\u{07}$ ")
        await settle(view)
        view.selectLastCommandOutput()
        XCTAssertNil(view.testingSelectionText())
    }

    func testScrollsToRevealOffscreenOutput() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.receive("\u{1b}]133;A\u{07}$ seq\r\n")
        view.receive((1 ... 5).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        view.receive("\u{1b}]133;A\u{07}$ ")
        // Push the bracketed output far above the viewport.
        for i in 0 ..< 80 { view.receive("filler \(i)\r\n") }
        await settle(view)

        view.selectLastCommandOutput()
        // The filler printed without marks, so the last two marks still bracket the seq
        // output — now far above the viewport. Extraction must read it regardless.
        XCTAssertEqual(view.testingSelectionText(),
                       (1 ... 5).map { "line \($0)" }.joined(separator: "\n"))
    }
}
