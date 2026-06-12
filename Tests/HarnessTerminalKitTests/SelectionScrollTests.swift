import AppKit
import Metal
import XCTest
import HarnessTerminalRenderer
import HarnessTheme
@testable import HarnessTerminalKit

// XCTest pulls in ApplicationServices, whose QuickDraw `RGBColor` shadows ours.
private typealias RGBColor = HarnessTheme.RGBColor

/// #161: mouse selection is content-anchored (absolute buffer lines), so scrolling — and new
/// output pushing lines into history — must neither clear it nor change what it extracts.
@MainActor
final class SelectionScrollTests: XCTestCase {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func settle(_ view: HarnessTerminalSurfaceView) async {
        view.testingWaitForEmulatorIdle()
        await drainMainQueue()
    }

    private func runSurvivesScrolling(offMain: Bool) async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: offMain)
        for i in 0 ..< 60 { view.receive("history line \(i) padded out for selection\r\n") }
        await settle(view)

        // A drag's end state on visible content (viewport rows 2…3).
        view.testingSetSelection(anchor: (row: 2, column: 0), head: (row: 3, column: 12))
        let before = view.testingSelectionText()
        XCTAssertNotNil(before, "selection on visible content must extract (offMain=\(offMain))")

        // Scroll far enough that the selected lines leave the viewport entirely.
        view.testingScrollBy(lines: 30)
        XCTAssertEqual(view.testingSelectionText(), before,
                       "scrolling must not clear or shift the selection (offMain=\(offMain))")

        // Smooth (fractional) scrolling included, and scrolling back down too.
        view.testingScrollByContinuous(lines: -7.5)
        XCTAssertEqual(view.testingSelectionText(), before,
                       "continuous scrolling must keep the selection (offMain=\(offMain))")
    }

    func testSelectionSurvivesScrollingSyncPipeline() async {
        await runSurvivesScrolling(offMain: false)
    }

    func testSelectionSurvivesScrollingOffMainPipeline() async {
        await runSurvivesScrolling(offMain: true)
    }

    func testSelectionStaysOnContentAsNewOutputArrives() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        for i in 0 ..< 30 { view.receive("steady line \(i)\r\n") }
        await settle(view)

        view.testingSetSelection(anchor: (row: 1, column: 0), head: (row: 1, column: 12))
        let before = view.testingSelectionText()
        XCTAssertNotNil(before)

        // New output pushes the selected line further into history; the selection rides it.
        for i in 30 ..< 45 { view.receive("steady line \(i)\r\n") }
        await settle(view)
        XCTAssertEqual(view.testingSelectionText(), before,
                       "new output must not shift a content-anchored selection")
    }

    func testEvictedSelectionClampsInsteadOfCrashing() async {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        for i in 0 ..< 20 { view.receive("early line \(i)\r\n") }
        await settle(view)
        view.testingSetSelection(anchor: (row: 0, column: 0), head: (row: 0, column: 10))
        XCTAssertNotNil(view.testingSelectionText())

        // Push far past the selection; even if the ring evicts the anchored lines, resolution
        // clamps to the retained buffer (copy mode's convention) — never traps.
        let flood = String(repeating: "flood line that keeps the parser busy\r\n", count: 30_000)
        view.receive(flood)
        await settle(view)
        _ = view.testingSelectionText() // must not crash; content may have shifted/evicted
        view.testingScrollBy(lines: 5)
        _ = view.testingSelectionText()
    }

    /// The rendered highlight moves WITH the content when the viewport scrolls (Metal-gated).
    func testPresentedSelectionShadingRebasesAcrossScroll() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()

        let selectionBG = RGBColor(red: 60, green: 80, blue: 200)
        view.testingSetSelectionColors(background: selectionBG, foreground: nil)
        for i in 0 ..< 60 { view.receive("scroll shade line \(i) content\r\n") }
        await settle(view)
        view.testingForceRender()
        guard view.testingLastPresentedFrame != nil else {
            throw XCTSkip("no present happened (drawable unavailable)")
        }

        view.testingSetSelection(anchor: (row: 2, column: 0), head: (row: 2, column: 8))
        view.testingForceRender()
        let atRest = try XCTUnwrap(view.testingLastPresentedFrame)
        XCTAssertEqual(atRest.cell(row: 2, column: 4)?.background, RenderColor(selectionBG))

        // Scroll 3 lines back into history: the selected content moves down 3 viewport rows,
        // and the shading must move with it.
        view.testingScrollBy(lines: 3)
        await settle(view)
        view.testingForceRender()
        let scrolled = try XCTUnwrap(view.testingLastPresentedFrame)
        XCTAssertEqual(scrolled.cell(row: 5, column: 4)?.background, RenderColor(selectionBG),
                       "highlight must follow the content, not the viewport")
        XCTAssertNotEqual(scrolled.cell(row: 2, column: 4)?.background, RenderColor(selectionBG),
                          "the old viewport row must not stay shaded")
    }
}
