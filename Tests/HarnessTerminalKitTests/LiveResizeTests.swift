import AppKit
import Metal
import XCTest
@testable import HarnessTerminalKit

/// Headless coverage of the glitchless live-resize behavior: the layer's transaction-present
/// mode is owned by the NSView live-resize lifecycle, the grid origin freezes for the duration
/// of a drag (no per-pixel shimmer), and the debounced grid+PTY commit flushes the moment the
/// drag ends instead of waiting out the coalescing delay.
@MainActor
final class LiveResizeTests: XCTestCase {
    func testLiveResizeLifecycleTogglesTransactionPresentMode() {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        XCTAssertFalse(view.testingPresentsWithTransaction)
        view.viewWillStartLiveResize()
        XCTAssertTrue(view.testingPresentsWithTransaction)
        view.viewDidEndLiveResize()
        XCTAssertFalse(view.testingPresentsWithTransaction)
    }

    func testLiveResizeFreezesOriginOnlyAfterFirstLayout() {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        // Before the first sized layout there is no meaningful origin to anchor.
        view.viewWillStartLiveResize()
        XCTAssertNil(view.testingLiveResizeFrozenOrigin)
        view.viewDidEndLiveResize()

        view.testingMarkGridSized()
        view.viewWillStartLiveResize()
        XCTAssertNotNil(view.testingLiveResizeFrozenOrigin)
        view.viewDidEndLiveResize()
        XCTAssertNil(view.testingLiveResizeFrozenOrigin)
    }

    func testViewDidEndLiveResizeFlushesPendingCommitImmediately() {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        var resizes: [(Int, Int)] = []
        view.onResize = { resizes.append(($0, $1)) }

        view.testingScheduleResizeCommit(cols: 100, rows: 30)
        XCTAssertTrue(view.testingHasPendingResizeCommit)
        XCTAssertEqual(view.testingGridSize.cols, 80) // still debouncing — not yet committed

        view.viewDidEndLiveResize()
        XCTAssertFalse(view.testingHasPendingResizeCommit)
        XCTAssertEqual(view.testingGridSize.cols, 100)
        XCTAssertEqual(view.testingGridSize.rows, 30)
        XCTAssertEqual(resizes.count, 1) // exactly one SIGWINCH, fired synchronously at drag end
        XCTAssertEqual(resizes.first?.0, 100)

        // The cancelled asyncAfter copy must not re-fire the commit once the debounce elapses.
        let settle = expectation(description: "debounce window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(resizes.count, 1)
    }

    func testDebouncedCommitStillFiresWithoutLiveResize() {
        // Animated (non-drag) resizes — sidebar slides, tiling — never enter live resize and
        // must keep coalescing to a single commit after the delay.
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        var resizes = 0
        view.onResize = { _, _ in resizes += 1 }
        view.testingScheduleResizeCommit(cols: 90, rows: 28)
        XCTAssertEqual(view.testingGridSize.cols, 80) // debounced, not immediate
        let fired = expectation(description: "debounce fired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { fired.fulfill() }
        wait(for: [fired], timeout: 2)
        XCTAssertEqual(view.testingGridSize.cols, 90)
        XCTAssertEqual(resizes, 1)
    }

    // MARK: - computeGridGeometry (pure)

    func testBalancedPaddingCentersSubCellRemainder() {
        // 805px wide, 10px cells, no padding: 80 cols with a 5px remainder → 2px left (odd px right).
        let g = HarnessTerminalSurfaceView.computeGridGeometry(
            pixelWidth: 805, pixelHeight: 600,
            basePadX: 0, basePadY: 0,
            cellWidth: 10, cellHeight: 20,
            balanced: true, frozenOrigin: nil
        )
        XCTAssertEqual(g.cols, 80)
        XCTAssertEqual(g.rows, 30)
        XCTAssertEqual(g.originX, 2)
        XCTAssertEqual(g.originY, 0)
    }

    func testUnbalancedOriginIsPaddingInset() {
        let g = HarnessTerminalSurfaceView.computeGridGeometry(
            pixelWidth: 805, pixelHeight: 605,
            basePadX: 8, basePadY: 8,
            cellWidth: 10, cellHeight: 20,
            balanced: false, frozenOrigin: nil
        )
        XCTAssertEqual(g.originX, 8)
        XCTAssertEqual(g.originY, 8)
    }

    func testFrozenOriginHeldSteadyAcrossSubCellWidths() {
        // The shimmer scenario: width grows pixel by pixel inside one cell column; balanced
        // re-centering would alternate the origin between 2 and 3 — frozen keeps it constant.
        for width in 804...809 {
            let g = HarnessTerminalSurfaceView.computeGridGeometry(
                pixelWidth: width, pixelHeight: 605,
                basePadX: 0, basePadY: 0,
                cellWidth: 10, cellHeight: 20,
                balanced: true, frozenOrigin: (x: 4, y: 1)
            )
            XCTAssertEqual(g.cols, 80, "width \(width)")
            XCTAssertEqual(g.originX, 4, "width \(width)")
            XCTAssertEqual(g.originY, 1, "width \(width)")
        }
    }

    func testFrozenOriginClampsWhenShrinkWouldClipLastColumn() {
        // Frozen 6px in; shrink to 803px: 80 cols × 10px = 800 → only 3px of slack. The origin
        // must slide to 3 so the last column stays fully visible (once per cell boundary,
        // not every pixel).
        let g = HarnessTerminalSurfaceView.computeGridGeometry(
            pixelWidth: 803, pixelHeight: 600,
            basePadX: 0, basePadY: 0,
            cellWidth: 10, cellHeight: 20,
            balanced: true, frozenOrigin: (x: 6, y: 0)
        )
        XCTAssertEqual(g.cols, 80)
        XCTAssertEqual(g.originX, 3)
        XCTAssertEqual(g.originY, 0)
    }

    func testFrozenOriginClampSlidesWhenGrowthCrossesCellBoundary() {
        // A grow-drag crossing a cell boundary: the new column consumes the slack, so the frozen
        // origin must slide back just enough to keep the new last column fully visible.
        // 809px: 80 cols, slack 9 → frozen 6 held. 812px: 81 cols (810px), slack 2 → slides to 2.
        let before = HarnessTerminalSurfaceView.computeGridGeometry(
            pixelWidth: 809, pixelHeight: 600,
            basePadX: 0, basePadY: 0,
            cellWidth: 10, cellHeight: 20,
            balanced: true, frozenOrigin: (x: 6, y: 0)
        )
        XCTAssertEqual(before.cols, 80)
        XCTAssertEqual(before.originX, 6)
        let after = HarnessTerminalSurfaceView.computeGridGeometry(
            pixelWidth: 812, pixelHeight: 600,
            basePadX: 0, basePadY: 0,
            cellWidth: 10, cellHeight: 20,
            balanced: true, frozenOrigin: (x: 6, y: 0)
        )
        XCTAssertEqual(after.cols, 81)
        XCTAssertEqual(after.originX, 2)
    }

    func testComputeGridGeometryMatchesLegacyInlineMath() {
        // Differential sweep pinning the extraction byte-equivalent to the old in-place math for
        // the non-resize path (the #43 lesson: pin shared semantics against an independent oracle).
        for (cellW, cellH) in [(7, 15), (10, 20), (17, 36)] {
            for pad in [0, 8, 13] {
                for balanced in [true, false] {
                    for pw in stride(from: 1, through: 900, by: 1) {
                        let ph = (pw * 3) / 4 + 1
                        let g = HarnessTerminalSurfaceView.computeGridGeometry(
                            pixelWidth: pw, pixelHeight: ph,
                            basePadX: pad, basePadY: pad,
                            cellWidth: cellW, cellHeight: cellH,
                            balanced: balanced, frozenOrigin: nil
                        )
                        // Legacy math, replicated verbatim from the pre-extraction updateGridSize.
                        var ox = pad
                        var oy = pad
                        let usableW = max(1, pw - 2 * ox)
                        let usableH = max(1, ph - 2 * oy)
                        let cols = max(1, usableW / cellW)
                        let rows = max(1, usableH / cellH)
                        if balanced {
                            ox += (usableW - cols * cellW) / 2
                            oy += (usableH - rows * cellH) / 2
                        }
                        XCTAssertEqual(g.cols, cols, "pw=\(pw) cell=\(cellW) pad=\(pad)")
                        XCTAssertEqual(g.rows, rows, "ph=\(ph) cell=\(cellH) pad=\(pad)")
                        XCTAssertEqual(g.originX, ox, "pw=\(pw) cell=\(cellW) pad=\(pad) balanced=\(balanced)")
                        XCTAssertEqual(g.originY, oy, "ph=\(ph) cell=\(cellH) pad=\(pad) balanced=\(balanced)")
                    }
                }
            }
        }
    }

    // MARK: - Teardown and stale-commit hazards

    func testDetachMidDragUnwindsLiveResizeState() {
        // A view can leave the window mid-drag (tab close / pane remount) and AppKit does not
        // guarantee viewDidEndLiveResize. The instance is cached and re-hosted, so the teardown
        // hook must unwind the transaction-present latch, the frozen origin, and the pending
        // commit — otherwise every later present pays the synchronous path outside any resize.
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.testingMarkGridSized()
        view.viewWillStartLiveResize()
        view.testingScheduleResizeCommit(cols: 120, rows: 40)
        XCTAssertTrue(view.testingPresentsWithTransaction)
        XCTAssertNotNil(view.testingLiveResizeFrozenOrigin)
        XCTAssertTrue(view.testingHasPendingResizeCommit)

        view.viewDidMoveToWindow() // window == nil → the teardown branch

        XCTAssertFalse(view.testingPresentsWithTransaction)
        XCTAssertNil(view.testingLiveResizeFrozenOrigin)
        XCTAssertFalse(view.testingHasPendingResizeCommit)
        XCTAssertEqual(view.testingGridSize.cols, 80) // cancelled, not flushed — layout re-schedules on re-attach
    }

    func testFlushedCommitDoesNotResurrectStaleSizeAfterDebounce() {
        // Makes the flush's work.cancel() load-bearing: if the asyncAfter copy weren't cancelled,
        // it would re-commit the STALE drag size over a newer one once the debounce elapses
        // (the cols guard passes — 110 ≠ 100 — so idempotence alone does not protect this).
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        var resizes: [(Int, Int)] = []
        view.onResize = { resizes.append(($0, $1)) }

        view.testingScheduleResizeCommit(cols: 100, rows: 30)
        view.viewDidEndLiveResize() // flush commits 100×30
        XCTAssertEqual(view.testingGridSize.cols, 100)
        view.testingResizeGrid(cols: 110, rows: 32) // a newer size lands right after the drag

        let settle = expectation(description: "debounce window elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(view.testingGridSize.cols, 110, "stale flushed commit must not resurrect")
        XCTAssertEqual(resizes.map(\.0), [100, 110])
    }

    // MARK: - Instrumentation math

    func testPresentPercentileMath() {
        let samples: [UInt64] = (1...100).map { UInt64($0) * 1000 } // 1…100µs as ns
        let p = FrameSignposter.percentilesMicros(samples)
        XCTAssertEqual(p.p50, 51) // sorted[50] (0-indexed) = 51µs
        XCTAssertEqual(p.p95, 96) // sorted[95] = 96µs
        XCTAssertEqual(p.max, 100)
        let empty = FrameSignposter.percentilesMicros([])
        XCTAssertEqual(empty.p50, 0)
        XCTAssertEqual(empty.max, 0)
    }

    // MARK: - Window-hosted routing (real Metal renderer; skips when unavailable)

    func testWindowHostedLiveResizeRoutesPresentsThroughTransactionSyncPath() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view // viewDidMoveToWindow → buildRenderer + first layout path
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        if !view.testingRepaintLastFrame() { // ensure a cached presentable frame exists
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
        }
        guard view.testingRepaintLastFrame() else { throw XCTSkip("no presentable frame (drawable unavailable)") }
        XCTAssertEqual(view.testingLastPresentScheduleNanos, 0, "pre-drag presents are async")

        view.viewWillStartLiveResize()
        XCTAssertTrue(view.testingRepaintLastFrame(), "present should succeed during live resize")
        XCTAssertGreaterThan(
            view.testingLastPresentScheduleNanos, 0,
            "live-resize presents must take the transaction-synchronized path"
        )

        // The REAL updateGridSize must hold the frozen origin across a sub-cell window growth.
        let frozen = view.testingOriginOffset
        var frame = window.frame
        frame.size.width += 3
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.testingOriginOffset.x, frozen.x, "origin must stay frozen during the drag")

        view.viewDidEndLiveResize()
        if view.testingRepaintLastFrame() { // generation may have advanced if the flush committed
            XCTAssertEqual(view.testingLastPresentScheduleNanos, 0, "post-drag presents return to async")
        }
        XCTAssertFalse(view.testingPresentsWithTransaction)
    }

    // MARK: - Near-free drag repaints (row-cache reuse under the frozen origin)

    private func makeHostedView(in window: NSWindow) throws -> HarnessTerminalSurfaceView {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testSubCellDragRepaintsReuseEveryRow() throws {
        // The resize-lag fix: once the renderer cache holds the presented frame's rows, a sub-cell
        // drag tick must encode ZERO rows — the cache keys (cols/rows/origin) are all stable under
        // the frozen origin, so the repaint is an empty-damage full-reuse present.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)

        for i in 0 ..< 50 { view.receive("line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender() // damage-path present → cache holds this frame's rows
        guard view.testingRepaintCacheCoherent else { throw XCTSkip("no present happened (drawable unavailable)") }
        let rows = view.testingGridSize.rows

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        // A 1px growth stays inside the current cell column: pure drawable-size change.
        var frame = window.frame
        frame.size.width += 1
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let stats = view.testingLastRenderStats else { throw XCTSkip("present dropped") }
        XCTAssertEqual(stats.encodedRows, 0, "sub-cell drag tick must reuse every row")
        XCTAssertEqual(stats.reusedRows, rows)

        // Second sub-cell tick: the first 0-encode present stored the uploaded-instance cache,
        // so this one binds it zero-copy — no instance bytes cross to the GPU at all.
        frame.size.width += 1
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let second = view.testingLastRenderStats else { throw XCTSkip("present dropped") }
        XCTAssertEqual(second.encodedRows, 0)
        XCTAssertEqual(second.instanceUploadBytes, 0, "steady-state drag ticks bind the uploaded cache zero-copy")
    }

    func testRepaintAfterPreviewPaysExactlyOneCachePopulatingRebuild() throws {
        // The coherence gate: a preview reflow replaces `lastPresentedResult` WITHOUT presenting,
        // so the next repaint must rebuild through the cache-populating path (all rows encoded) —
        // and the tick after that must be free again. Asserted via the coherence seam + stats.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)

        for i in 0 ..< 50 { view.receive("wrap test line \(i) abcdefghij\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingRepaintCacheCoherent else { throw XCTSkip("no present happened (drawable unavailable)") }

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        // Grow far enough to cross a cell-column boundary → updateGridSize runs the re-wrap
        // preview, which replaces the cached frame without presenting it.
        guard let renderer = view.testingLastRenderStats else { throw XCTSkip("no stats") }
        _ = renderer
        var frame = window.frame
        frame.size.width += 40 // ≥ one cell column at any reasonable font size
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let rebuild = view.testingLastRenderStats else { throw XCTSkip("present dropped") }
        let rows = view.testingGridSize.rows
        XCTAssertEqual(rebuild.encodedRows, rows, "first repaint after a preview rebuilds every row")
        XCTAssertTrue(view.testingRepaintCacheCoherent, "the rebuild repopulated the cache")

        // Next sub-cell tick: free again.
        frame.size.width += 1
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let reuse = view.testingLastRenderStats else { throw XCTSkip("present dropped") }
        XCTAssertEqual(reuse.encodedRows, 0, "the tick after the rebuild reuses every row")
    }

    func testOutputPresentsDeferDuringDragAndFlushAfter() throws {
        // Single present source during a drag: output arriving mid-drag must not present through
        // the scheduler's async path (it marks dirty instead); the deferred work flushes once the
        // drag ends and the mode clears.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        view.receive("before drag\r\n")
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()

        view.viewWillStartLiveResize()
        var presents = 0
        view.onRenderStats = { _ in presents += 1 }
        view.receive("mid-drag output\r\n")
        view.testingWaitForEmulatorIdle()
        // Drain the main hop the parse completion queued; its presentNow must hit the hold.
        let hop = expectation(description: "main hop drained")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 2)
        XCTAssertEqual(presents, 0, "mid-drag output must not present through the async path")
        XCTAssertTrue(view.testingRenderPending, "the deferred output stays marked dirty")

        view.viewDidEndLiveResize()
        XCTAssertFalse(view.testingPresentsWithTransaction)
        // The next scheduler tick (display cadence) presents the freshest frame; drive it directly.
        view.testingForceRender()
        XCTAssertGreaterThan(presents, 0, "deferred output flushes after the drag")
    }

    func testAsyncRenderPathStillPresentsOutsideDrag() throws {
        // The guard that defers the scheduler's async render entry during a drag must be inert
        // outside one: a display tick with pending output presents instead of re-marking dirty.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        view.receive("warmup\r\n")
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()

        var presents = 0
        view.onRenderStats = { _ in presents += 1 }
        view.receive("echo\r\n")
        view.testingWaitForEmulatorIdle()
        // Drain the parse-completion main hop so the output's dirty mark has landed.
        let hop = expectation(description: "main hop drained")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 2)
        XCTAssertTrue(view.testingRenderPending, "output marked the surface dirty")
        XCTAssertTrue(view.testingSchedulerTick(), "the tick must run the async render, not defer")
        // The off-main build presents on the next main hop; drain it.
        let settle = expectation(description: "off-main build presented")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertGreaterThan(presents, 0, "output outside a drag presents through the async path")
        XCTAssertFalse(view.testingRenderPending, "nothing re-marked dirty (the hold is inert)")
    }
}
