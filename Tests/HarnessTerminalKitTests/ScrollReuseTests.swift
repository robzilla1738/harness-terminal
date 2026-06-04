import AppKit
import Metal
import XCTest
@testable import HarnessTerminalKit
import HarnessTerminalRenderer

/// End-to-end scroll-delta reuse through the real surface pipeline: a pure scrollback scroll must
/// shift-rebuild the frame (FrameBuilder) and rotate the renderer's row cache instead of paying a
/// full re-encode per tick. Window-hosted with a real Metal renderer; skips when unavailable.
@MainActor
final class ScrollReuseTests: XCTestCase {
    private func makeHostedView(in window: NSWindow) throws -> HarnessTerminalSurfaceView {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view // viewDidMoveToWindow → buildRenderer + first layout path
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testPureScrollRotatesRowCacheInsteadOfFullEncode() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        var lastStats: TerminalRenderStats?
        view.onRenderStats = { lastStats = $0 }

        for i in 0 ..< 200 { view.receive("history line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender() // live frame: seeds the row cache + the shift source
        guard lastStats != nil else { throw XCTSkip("no present happened (drawable unavailable)") }
        let rows = view.testingGridSize.rows

        lastStats = nil
        view.testingScrollBy(lines: 3) // pure scroll: offset 0 → 3, no output in between
        view.testingForceRender()
        guard let scrolled = lastStats else { throw XCTSkip("scrolled present dropped (drawable unavailable)") }
        XCTAssertEqual(scrolled.encodedRows, 3, "only the newly-exposed rows re-encode")
        XCTAssertEqual(scrolled.reusedRows, rows - 3, "kept rows rotate through the cache")

        // Scroll back toward live: the k→k′ and k→0 transitions ride the same path.
        lastStats = nil
        view.testingScrollBy(lines: -3)
        view.testingForceRender()
        guard let back = lastStats else { throw XCTSkip("return present dropped (drawable unavailable)") }
        XCTAssertEqual(back.encodedRows, 3)
        XCTAssertEqual(back.reusedRows, rows - 3)
    }

    func testOutputWhileScrolledFallsBackToFullRebuild() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        var lastStats: TerminalRenderStats?
        view.onRenderStats = { lastStats = $0 }

        for i in 0 ..< 100 { view.receive("line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard lastStats != nil else { throw XCTSkip("no present happened (drawable unavailable)") }
        let rows = view.testingGridSize.rows

        // New output arrives, THEN the user scrolls: the window over history changed shape
        // (content moved under the offset), so the shift fast path must refuse and rebuild.
        view.receive("fresh output\r\n")
        view.testingWaitForEmulatorIdle()
        lastStats = nil
        view.testingScrollBy(lines: 2)
        view.testingForceRender()
        guard let scrolled = lastStats else { throw XCTSkip("scrolled present dropped (drawable unavailable)") }
        XCTAssertEqual(scrolled.encodedRows, rows, "output since the last frame forces a full re-encode")
        XCTAssertEqual(scrolled.reusedRows, 0)
    }
}
