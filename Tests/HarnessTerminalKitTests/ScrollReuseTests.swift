import AppKit
import Metal
import XCTest
@testable import HarnessTerminalKit
import HarnessTerminalRenderer

/// End-to-end scroll-delta reuse through the real surface pipeline: a pure scrollback scroll must
/// shift-rebuild the frame (FrameBuilder) and rotate the renderer's row cache instead of paying a
/// full re-encode per tick. Scrolled frames carry the smooth-scroll peek row (rows+1 tall, one
/// display-only row below the viewport), so the scrolled regime rotates rows+1 rows and the
/// live↔scrolled transitions pay one full rebuild for the shape change (the per-gesture entry
/// cost). Window-hosted with a real Metal renderer; skips when unavailable.
@MainActor
final class ScrollReuseTests: XCTestCase {
    private func makeHostedView(in window: NSWindow) throws -> HarnessTerminalSurfaceView {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view // viewDidMoveToWindow → buildRenderer + first layout path
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }

    func testPureScrollRotatesRowCacheInsteadOfFullEncode() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = makeWindow()
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        var lastStats: TerminalRenderStats?
        view.onRenderStats = { lastStats = $0 }

        for i in 0 ..< 200 { view.receive("history line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender() // live frame: seeds the row cache + the shift source
        guard lastStats != nil else { throw XCTSkip("no present happened (drawable unavailable)") }
        let rows = view.testingGridSize.rows
        let frameRows = rows + 1 // scrolled frames carry the peek row

        // Gesture entry (live → scrolled): the frame grows by the peek row, so the shift path
        // refuses on the shape change and one full rebuild seeds the rows+1 cache.
        lastStats = nil
        view.testingScrollBy(lines: 3)
        view.testingForceRender()
        guard let entry = lastStats else { throw XCTSkip("scrolled present dropped (drawable unavailable)") }
        XCTAssertEqual(entry.encodedRows, frameRows, "live→scrolled pays one shape-change rebuild")

        // Scrolled → scrolled: the pure-scroll rotation, now over rows+1.
        lastStats = nil
        view.testingScrollBy(lines: 3) // pure scroll: offset 3 → 6, no output in between
        view.testingForceRender()
        guard let scrolled = lastStats else { throw XCTSkip("scrolled present dropped (drawable unavailable)") }
        XCTAssertEqual(scrolled.encodedRows, 3, "only the newly-exposed rows re-encode")
        XCTAssertEqual(scrolled.reusedRows, frameRows - 3, "kept rows rotate through the cache")

        // Scroll back toward live: the k→k′ transition rides the same path.
        lastStats = nil
        view.testingScrollBy(lines: -3)
        view.testingForceRender()
        guard let back = lastStats else { throw XCTSkip("return present dropped (drawable unavailable)") }
        XCTAssertEqual(back.encodedRows, 3)
        XCTAssertEqual(back.reusedRows, frameRows - 3)

        // Landing at the live bottom drops the peek row (byte-identical live frame), paying the
        // mirror shape-change rebuild.
        lastStats = nil
        view.testingScrollBy(lines: -3)
        view.testingForceRender()
        guard let landed = lastStats else { throw XCTSkip("landing present dropped (drawable unavailable)") }
        XCTAssertEqual(landed.encodedRows, rows, "scrolled→live pays the mirror shape-change rebuild")
    }

    func testFractionOnlyScrollTickReusesEveryRow() throws {
        // The pixel-smooth path: a sub-line scroll that doesn't cross an integer line re-presents
        // the cached frame with only a new translate uniform — zero rows encoded.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = makeWindow()
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        var lastStats: TerminalRenderStats?
        view.onRenderStats = { lastStats = $0 }

        for i in 0 ..< 200 { view.receive("history line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard lastStats != nil else { throw XCTSkip("no present happened (drawable unavailable)") }
        let rows = view.testingGridSize.rows

        // Entry: P = 0.5 → offset ceil = 1, fraction 0.5 — offset changed, rebuild expected.
        lastStats = nil
        view.testingScrollByContinuous(lines: 0.5)
        view.testingForceRender()
        guard lastStats != nil else { throw XCTSkip("present dropped (drawable unavailable)") }
        XCTAssertEqual(view.testingScrollPosition.offset, 1)
        XCTAssertEqual(view.testingScrollPosition.fraction, 0.5, accuracy: 0.0001)

        // Fraction-only tick: P = 0.8 → offset still 1, fraction 0.2. The repaint must reuse
        // every cached row (uniform-only present).
        lastStats = nil
        view.testingScrollByContinuous(lines: 0.3)
        guard let fractionTick = lastStats else { throw XCTSkip("fraction repaint dropped (drawable unavailable)") }
        XCTAssertEqual(view.testingScrollPosition.offset, 1)
        XCTAssertEqual(view.testingScrollPosition.fraction, 0.2, accuracy: 0.0001)
        XCTAssertEqual(fractionTick.encodedRows, 0, "a fraction-only tick re-encodes nothing")
        XCTAssertEqual(fractionTick.reusedRows, rows + 1, "every row (incl. the peek) is reused")

        // Second fraction tick: the first stored the uploaded-instance cache, so this one binds
        // zero-copy — the steady-state trackpad tick is a 4-byte uniform update, nothing more.
        lastStats = nil
        view.testingScrollByContinuous(lines: 0.1)
        guard let second = lastStats else { throw XCTSkip("fraction repaint dropped (drawable unavailable)") }
        XCTAssertEqual(second.encodedRows, 0)
        XCTAssertEqual(second.instanceUploadBytes, 0, "steady-state fraction ticks bind the uploaded cache zero-copy")

        // Clamp to the live bottom lands exactly on fraction 0.
        view.testingScrollByContinuous(lines: -5)
        XCTAssertEqual(view.testingScrollPosition.offset, 0)
        XCTAssertEqual(view.testingScrollPosition.fraction, 0)
    }

    func testContinuousScrollSplitMath() throws {
        // Pure state-machine coverage of the ceil/fraction split + clamping (no Metal needed —
        // but the hosted view keeps historyCount real).
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = makeWindow()
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        for i in 0 ..< 50 { view.receive("line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()

        view.testingScrollByContinuous(lines: 2.25) // P = 2.25 → ceil 3, fraction 0.75
        XCTAssertEqual(view.testingScrollPosition.offset, 3)
        XCTAssertEqual(view.testingScrollPosition.fraction, 0.75, accuracy: 0.0001)

        view.testingScrollByContinuous(lines: 0.75) // P = 3.0 → exactly on a line
        XCTAssertEqual(view.testingScrollPosition.offset, 3)
        XCTAssertEqual(view.testingScrollPosition.fraction, 0, accuracy: 0.0001)

        view.testingScrollByContinuous(lines: -10) // clamp at the live bottom
        XCTAssertEqual(view.testingScrollPosition.offset, 0)
        XCTAssertEqual(view.testingScrollPosition.fraction, 0)

        view.testingScrollByContinuous(lines: 10_000) // clamp at the top of history
        let top = view.testingScrollPosition
        XCTAssertEqual(top.fraction, 0, accuracy: 0.0001, "the top clamp anchors on a whole line")
        XCTAssertLessThanOrEqual(top.offset, 50)
    }

    func testOutputWhileScrolledFallsBackToFullRebuild() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = makeWindow()
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
        // (content moved under the offset), so the shift fast path must refuse and rebuild
        // the full scrolled frame (rows + the peek row).
        view.receive("fresh output\r\n")
        view.testingWaitForEmulatorIdle()
        lastStats = nil
        view.testingScrollBy(lines: 2)
        view.testingForceRender()
        guard let scrolled = lastStats else { throw XCTSkip("scrolled present dropped (drawable unavailable)") }
        XCTAssertEqual(scrolled.encodedRows, rows + 1, "output since the last frame forces a full re-encode")
        XCTAssertEqual(scrolled.reusedRows, 0)
    }
}
