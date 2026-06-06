import AppKit
import Metal
import XCTest
@testable import HarnessTerminalKit

/// Occlusion gating end to end: a covered/minimized pane keeps parsing but never acquires a
/// drawable or presents; visibility returning presents one fresh frame with everything that
/// arrived while hidden.
@MainActor
final class OcclusionTests: XCTestCase {
    private func makeHostedView(in window: NSWindow) throws -> HarnessTerminalSurfaceView {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Pump the main run loop so the off-main pipeline's main-hop (present) lands.
    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func presentedText(_ view: HarnessTerminalSurfaceView) -> String {
        guard let frame = view.testingLastPresentedFrame else { return "" }
        return String(frame.cells.compactMap { cell in
            cell.codepoint != 0 ? Unicode.Scalar(cell.codepoint).map(Character.init) : nil
        })
    }

    func testOccludedPaneParsesButNeverPresents() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        view.receive("before\r\n")
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingLastPresentedFrame != nil else {
            throw XCTSkip("no present happened (drawable unavailable)")
        }
        XCTAssertTrue(presentedText(view).contains("before"))

        // Cover the window: output keeps flowing (parsing continues) but nothing presents —
        // neither the echo flush nor the display tick.
        view.testingSetWindowOccluded(true)
        view.receive("HIDDENMARKER\r\n")
        view.testingWaitForEmulatorIdle()
        pump()
        XCTAssertFalse(view.testingSchedulerTick(), "no present for an invisible window")
        XCTAssertFalse(presentedText(view).contains("HIDDENMARKER"),
                       "the covered pane must not have presented the new output")
        // The content is *parsed* — the grid is current even though nothing presented.
        let grid = view.testingReadGridSnapshot()
        let gridText = (0 ..< grid.rows).map { row in
            String((0 ..< grid.cols).compactMap { col in
                grid.cell(row: row, col: col).flatMap { Unicode.Scalar($0.codepoint).map(Character.init) }
            })
        }.joined()
        XCTAssertTrue(gridText.contains("HIDDENMARKER"), "parsing continues while covered")

        // Uncover: the accumulated damage presents on the next tick.
        view.testingSetWindowOccluded(false)
        XCTAssertTrue(view.testingSchedulerTick(), "visibility back → the held frame presents")
        pump() // the off-main build's present lands on a main hop
        XCTAssertTrue(presentedText(view).contains("HIDDENMARKER"))
    }

    func testReattachDropsStaleOcclusion() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        view.testingSetWindowOccluded(true)
        XCTAssertTrue(view.testingIsOccluded)
        // Detach (pane re-host): the stale occlusion described the departed window and must not
        // gate the re-hosted view — the new window's own occlusion notifications take over.
        window.contentView = nil
        window.contentView = view
        XCTAssertFalse(view.testingIsOccluded,
                       "re-hosting must not inherit the old window's occlusion")
    }
}
