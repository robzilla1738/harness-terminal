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

    func testDebouncedCommitDefersWhileDragHolds() {
        // ESCAPE-HATCH path (real-time reflow off): a stationary >60ms hold mid-drag lets the
        // debounce elapse. The commit must re-arm, not fire: a mid-drag commit bumps the generation
        // (dropping the in-flight preview) but its authoritative re-present defers while the layer
        // is in transaction mode — with the mouse still, the screen would freeze on a
        // stale-generation frame until the next pointer move. (With real-time reflow on, the live
        // path commits here instead — see testCommitFiresLiveAtBoundaryWithReflowOn.)
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.testingSetLiveResizeReflow(false)
        var resizes = 0
        view.onResize = { _, _ in resizes += 1 }
        view.testingMarkGridSized()
        view.viewWillStartLiveResize()
        view.testingScheduleResizeCommit(cols: 100, rows: 30)

        let held = expectation(description: "debounce elapsed mid-hold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { held.fulfill() }
        wait(for: [held], timeout: 2)
        XCTAssertEqual(view.testingGridSize.cols, 80, "no commit may land mid-drag")
        XCTAssertEqual(resizes, 0, "no mid-drag SIGWINCH")
        XCTAssertTrue(view.testingHasPendingResizeCommit, "the commit re-armed for the next window")

        view.viewDidEndLiveResize() // flush: transaction mode is off, the commit lands once
        XCTAssertEqual(view.testingGridSize.cols, 100)
        XCTAssertEqual(resizes, 1, "exactly one SIGWINCH, at release")
    }

    func testDragEndInvalidatesInFlightPreview() throws {
        // A drag that returns to its ORIGINAL size commits nothing (no generation bump, and the
        // back-to-original tick never updates previewCols), so drag-end must invalidate the
        // in-flight preview explicitly: token advanced + target cleared, making a late landing
        // for the intermediate width drop instead of stashing a wrong-width frame.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        for i in 0 ..< 40 { view.receive("end test line \(i) abcdefghij\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingRepaintCacheCoherent else { throw XCTSkip("no present happened (drawable unavailable)") }

        view.viewWillStartLiveResize()
        var frame = window.frame
        frame.size.width += 40 // boundary crossing: claims a preview token, sets the target
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let midDragTarget = view.testingPreviewTarget
        guard midDragTarget.cols > 0 else { throw XCTSkip("no boundary crossing at this cell size") }
        frame.size.width -= 40 // back to EXACTLY the original size before release
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.viewDidEndLiveResize()
        // (The drag-end flush may commit the stale armed size and immediately start a NEW preview
        // toward the settled size — that successor is legitimate; only the MID-DRAG build must die.)

        // A landing carrying the mid-drag target must now be dropped: the end-of-drag token claim
        // made every token from during the drag stale, independent of whether the flush bumped the
        // generation (a drag ending at its original size commits nothing).
        XCTAssertFalse(
            view.testingPresentResizePreview(cols: midDragTarget.cols, rows: midDragTarget.rows, token: 1),
            "a stale mid-drag preview landing after release must be dropped"
        )
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
        // These hosted cases pin the non-mutating re-wrap PREVIEW and the output-defer/cache-reuse
        // contracts of a drag. With real-time reflow on, a boundary crossing also commits the
        // authoritative grid (bumping the generation) and would race those assertions — so they run
        // the escape-hatch (defer-to-release) path, which still drives the same preview machinery.
        // The real-time commit path has its own dedicated coverage below.
        view.testingSetLiveResizeReflow(false)
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

    /// Drain one async resize-preview round: the build on the emulator queue (queue order — the
    /// preview was dispatched before this sync), then the main hop that lands it
    /// (`presentResizePreview` → stash + repaint).
    private func drainPreviewHop(_ view: HarnessTerminalSurfaceView) {
        view.testingWaitForEmulatorIdle()
        let hop = expectation(description: "preview main hop drained")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 2)
    }

    func testBoundaryTickPaysExactlyOneCachePopulatingRebuildThenFree() throws {
        // The boundary-crossing contract: the layout tick that crosses a cell boundary re-presents
        // the cached frame for free (the re-wrap builds async on the emulator queue — main never
        // blocks); the preview then lands on the next hop and pays the ONE cache-populating full
        // rebuild per geometry change; the tick after that is free again.
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
        guard let before = view.testingLastRenderStats else { throw XCTSkip("no stats") }

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        // Grow far enough to cross a cell-column boundary → updateGridSize schedules the async
        // re-wrap preview; the SAME layout pass re-presents the cached (old-wrap) frame for free.
        var frame = window.frame
        frame.size.width += 40 // ≥ one cell column at any reasonable font size
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let boundaryTick = view.testingLastRenderStats else { throw XCTSkip("present dropped") }
        XCTAssertEqual(boundaryTick.encodedRows, 0,
                       "the boundary tick itself re-presents the cached frame — main pays no rebuild")
        XCTAssertEqual(boundaryTick.cells, before.cells, "still the old-wrap frame on this tick")

        // The async preview lands: stash (coherence break) + immediate repaint through the
        // cache-populating full path — the one rebuild this geometry change pays. Setup proved
        // presents work in this environment, so a missing land is a FAILURE, not a skip — a
        // presentResizePreview that never runs must turn this test red.
        drainPreviewHop(view)
        guard let rebuild = view.testingLastRenderStats else { return XCTFail("no stats after drain") }
        XCTAssertNotEqual(rebuild.cells, before.cells,
                          "the async preview must land after the drain (re-wrapped cell count)")
        XCTAssertEqual(rebuild.cells, view.testingPreviewTarget.cols * view.testingPreviewTarget.rows,
                       "the landed frame is the drag target's re-wrap")
        // Content-keyed salvage: these short lines don't re-wrap at the wider grid, so every
        // row's rendered content is unchanged and the cache survives the column change — the
        // "rebuild" encodes ZERO rows (the Stage-3 win; a real re-wrap encodes its changed
        // suffix, pinned by MetalRendererTests.testColumnChangeReencodesOnlyChangedRows).
        XCTAssertEqual(rebuild.encodedRows, 0,
                       "unchanged content salvages every row across the column change")
        XCTAssertEqual(rebuild.reusedRows, view.testingPreviewTarget.rows)
        XCTAssertTrue(view.testingRepaintCacheCoherent, "the rebuild repopulated the cache")

        // Next sub-cell tick: free again. Neutralize the armed 60ms commit first — under CI load
        // the drain can outlast the debounce, and a fired commit bumps the generation and forces
        // a full rebuild, which would fail this assertion for timing reasons, not correctness.
        view.testingCancelPendingResizeCommit()
        frame.size.width += 1
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let reuse = view.testingLastRenderStats else { return XCTFail("present dropped") }
        XCTAssertEqual(reuse.encodedRows, 0, "the tick after the rebuild reuses every row")
    }

    func testPresentResizePreviewGuardsDropStaleLandings() throws {
        // The main-hop guards (stale token / stale drag target) only fire under racy production
        // interleavings (a hop queued before a newer boundary tick claims the token), so drive
        // them directly: each guard must independently drop the landing.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        for i in 0 ..< 40 { view.receive("guard test line \(i) abcdefghij\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingRepaintCacheCoherent else { throw XCTSkip("no present happened (drawable unavailable)") }

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        var frame = window.frame
        frame.size.width += 40 // one boundary crossing establishes a current target + token
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        drainPreviewHop(view)
        let target = view.testingPreviewTarget
        guard target.cols > 0 else { throw XCTSkip("no boundary crossing at this cell size") }
        guard let landed = view.testingLastRenderStats,
              landed.cells == target.cols * target.rows else {
            throw XCTSkip("preview present dropped (drawable unavailable)")
        }

        // Stale TOKEN: a hop carrying an old token (a newer claim superseded it) must drop, even
        // though the target still matches.
        XCTAssertFalse(view.testingPresentResizePreview(cols: target.cols, rows: target.rows, token: 0),
                       "a superseded token must be dropped")

        // Stale TARGET: a hop whose (cols, rows) no longer match the current drag target must
        // drop, even with the freshest token.
        let freshToken = view.testingClaimPreviewToken()
        XCTAssertFalse(view.testingPresentResizePreview(cols: target.cols + 5, rows: target.rows, token: freshToken),
                       "a superseded drag target must be dropped")

        // Happy path: the current target with the latest token lands.
        let currentToken = view.testingClaimPreviewToken()
        XCTAssertTrue(view.testingPresentResizePreview(cols: target.cols, rows: target.rows, token: currentToken),
                      "the current target with the latest token must land")
    }

    func testBoundaryTickDoesNotBlockMainOnBusyParser() throws {
        // The async-preview point: with a parse in flight on the emulator queue, the boundary
        // tick's layout must not park main behind it (the old synchronous preview either blocked
        // or skipped). The layout re-presents the cached frame immediately; the re-wrap lands
        // once the queue drains.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        for i in 0 ..< 50 { view.receive("busy parser line \(i) abcdefghij\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingRepaintCacheCoherent else { throw XCTSkip("no present happened (drawable unavailable)") }
        guard let before = view.testingLastRenderStats else { throw XCTSkip("no stats") }

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        // Queue a big parse, then cross a boundary while it's in flight. The preview build queues
        // BEHIND the parse on the serial queue; layout itself must not wait for either.
        let bulk = (0 ..< 2000).map { "flood \($0) abcdefghijklmnopqrstuvwxyz\r\n" }.joined()
        view.receive(bulk)
        var frame = window.frame
        frame.size.width += 40
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        guard let boundaryTick = view.testingLastRenderStats else { throw XCTSkip("present dropped") }
        XCTAssertEqual(boundaryTick.encodedRows, 0,
                       "boundary tick under load re-presents the cached frame without touching the queue")
        XCTAssertEqual(boundaryTick.cells, before.cells)

        // Once the parse + preview drain, the re-wrapped preview presents (the old code SKIPPED
        // the preview entirely when the parser was busy — re-wrap under load is the upgrade).
        // Setup proved presents work here, so a missing land is a failure, not a skip.
        drainPreviewHop(view)
        guard let rebuild = view.testingLastRenderStats else { return XCTFail("no stats after drain") }
        XCTAssertNotEqual(rebuild.cells, before.cells, "the preview must land once the queue drains")
        XCTAssertTrue(view.testingRepaintCacheCoherent, "preview landed and repopulated the cache")
    }

    func testStalePreviewBuildIsDroppedNotStashed() throws {
        // A slow preview landing after the drag moved to a DIFFERENT cell target must be dropped
        // outright (stashing it would re-present mis-wrapped content at the wrong grid size on
        // every later sub-cell repaint). Superseded here by a second boundary crossing whose
        // newer token + previewCols invalidate the first build.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        for i in 0 ..< 50 { view.receive("stale test line \(i) abcdefghij\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard view.testingRepaintCacheCoherent else { throw XCTSkip("no present happened (drawable unavailable)") }

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        // Two boundary crossings back-to-back WITHOUT draining between them: build #1 (intermediate
        // width) and build #2 (final width) both queue; #1 is dropped by the ON-QUEUE token skip
        // (it never reaches a main hop in this construction — the hop-side guards are pinned
        // separately by testPresentResizePreviewGuardsDropStaleLandings), leaving exactly the
        // final width's wrap on screen.
        var frame = window.frame
        frame.size.width += 40
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        frame.size.width += 40
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        drainPreviewHop(view)
        drainPreviewHop(view) // second round for the second build's hop
        guard let landed = view.testingLastRenderStats else { throw XCTSkip("present dropped") }
        let cols = view.testingGridSize.cols // commit is debounced — grid cols are pre-drag
        _ = cols
        // The presented frame must be the FINAL target's re-wrap: cells = previewCols × previewRows
        // of the last crossing, never the intermediate width's.
        XCTAssertEqual(landed.cells, view.testingPreviewTarget.cols * view.testingPreviewTarget.rows,
                       "only the latest boundary target's preview may land")
    }

    func testEncodeStatsSplitIsPopulatedAndBounded() throws {
        // The per-boundary instrumentation pin: buildInstancesNanos (CPU instance build) and
        // uploadNanos (GPU buffer upload) must be populated by a real encode and sum to no more
        // than encodeNanos (they are disjoint sub-spans of it) — so the split can never silently
        // regress to zero or double-count.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        for i in 0 ..< 30 { view.receive("stats split line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard let stats = view.testingLastRenderStats, stats.encodeNanos > 0 else {
            throw XCTSkip("no present happened (drawable unavailable)")
        }
        XCTAssertGreaterThan(stats.buildInstancesNanos, 0, "a real encode times the instance build")
        // Include the semaphore wait in the bound: the three sub-spans are DISJOINT intervals of
        // encodeNanos (build < semWait < upload in encode), so a future edit that lets the build
        // timer swallow the semaphore-wait region breaks this sum instead of passing silently.
        XCTAssertLessThanOrEqual(
            stats.buildInstancesNanos + stats.uploadNanos + stats.semaphoreWaitNanos,
            stats.encodeNanos,
            "build, upload, and semaphore-wait are disjoint sub-intervals of encodeNanos"
        )

        // The reuse path (the dominant drag tick: coherent empty-damage repaint) must keep the
        // split populated too — a regression zeroing the timers only on reuse would otherwise hide.
        guard view.testingRepaintCacheCoherent, view.testingRepaintLastFrame(),
              let reuse = view.testingLastRenderStats else {
            throw XCTSkip("no coherent repaint available")
        }
        XCTAssertEqual(reuse.encodedRows, 0, "precondition: this is the reuse path")
        XCTAssertGreaterThan(reuse.buildInstancesNanos, 0, "the reuse path still times the instance walk")
        XCTAssertLessThanOrEqual(
            reuse.buildInstancesNanos + reuse.uploadNanos + reuse.semaphoreWaitNanos,
            reuse.encodeNanos
        )
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

    // MARK: - Real-time live reflow (Ghostty parity)

    func testCommitFiresLiveAtBoundaryWithReflowOn() {
        // The headline behavior: with real-time reflow on (the default), a cell-boundary commit
        // during a drag updates the grid dimensions and fires the PTY SIGWINCH IMMEDIATELY — no
        // debounce, no re-arm — so the running program reflows live instead of at release.
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        XCTAssertTrue(view.testingLiveResizeReflowEnabled, "real-time reflow is on by default")
        var resizes: [(Int, Int)] = []
        view.onResize = { resizes.append(($0, $1)) }
        view.testingMarkGridSized()
        view.viewWillStartLiveResize()

        view.testingRequestLiveResizeCommit(cols: 100, rows: 30)
        XCTAssertEqual(view.testingGridSize.cols, 100, "the grid commits live, not at release")
        XCTAssertEqual(view.testingGridSize.rows, 30)
        XCTAssertEqual(resizes.count, 1, "exactly one SIGWINCH, fired mid-drag")
        XCTAssertEqual(resizes.first?.0, 100)
        XCTAssertFalse(view.testingHasPendingResizeCommit, "the live path arms no debounced commit")
        view.viewDidEndLiveResize()
    }

    func testLiveCommitFallsBackToDebounceOnMainConfinedPipeline() {
        // The real-time commit reflows the emulator ON the serial queue; with the off-main parser
        // pipeline disabled the emulator is main-confined (`receive` feeds it synchronously on
        // main), so the live path must fall back to the debounced drag-end commit — the same
        // confinement guard `updateResizePreview` and `commitGridSize` apply — instead of
        // mutating the emulator across two threads mid-drag.
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: false)
        XCTAssertTrue(view.testingLiveResizeReflowEnabled, "real-time reflow stays on by default")
        var resizes = 0
        view.onResize = { _, _ in resizes += 1 }
        view.testingMarkGridSized()
        view.viewWillStartLiveResize()

        view.testingRequestLiveResizeCommit(cols: 100, rows: 30)
        XCTAssertEqual(view.testingGridSize.cols, 80, "no live commit on the main-confined pipeline")
        XCTAssertEqual(resizes, 0, "no mid-drag SIGWINCH on the fallback path")
        XCTAssertTrue(view.testingHasPendingResizeCommit, "fell back to the debounced commit")

        view.viewDidEndLiveResize() // flush: the commit lands once, at release
        XCTAssertEqual(view.testingGridSize.cols, 100)
        XCTAssertEqual(view.testingGridSize.rows, 30)
        XCTAssertEqual(resizes, 1, "exactly one SIGWINCH, at release")
    }

    func testLivePTYVoteCoalescesToDistinctCellCounts() {
        // The PTY vote must fire once per DISTINCT cell count and never re-send an unchanged size
        // (the daemon re-ioctls on every identical vote, so a within-column drag must be silent).
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        var resizes: [(Int, Int)] = []
        view.onResize = { resizes.append(($0, $1)) }
        view.testingMarkGridSized()
        view.viewWillStartLiveResize()

        view.testingRequestLiveResizeCommit(cols: 100, rows: 30)
        view.testingRequestLiveResizeCommit(cols: 99, rows: 30)
        view.testingRequestLiveResizeCommit(cols: 98, rows: 30)
        XCTAssertEqual(resizes.map(\.0), [100, 99, 98], "each distinct cell count votes once")
        XCTAssertEqual(view.testingLastSentPTYSize?.cols, 98)
        // A repeat of the current size sends nothing (the cols/rows guard short-circuits it).
        view.testingRequestLiveResizeCommit(cols: 98, rows: 30)
        XCTAssertEqual(resizes.count, 3, "an unchanged cell count fires no redundant SIGWINCH")
        view.viewDidEndLiveResize()
    }

    func testLiveReflowCommitsGridAndPresentsMidDrag() throws {
        // End-to-end with a real renderer: a boundary crossing during a drag commits the
        // authoritative grid + SIGWINCH and presents the reflowed frame through the
        // transaction-synchronized path — all WITHOUT a viewDidEndLiveResize.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true) // real-time reflow on
        window.contentView = view
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        for i in 0 ..< 50 { view.receive("reflow line \(i) abcdefghij\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        let startCols = view.testingGridSize.cols
        var resizes: [(Int, Int)] = []
        view.onResize = { resizes.append(($0, $1)) }

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }
        var frame = window.frame
        frame.size.width += 40 // cross at least one cell column
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(view.testingGridSize.cols, startCols, "the grid reflows live during the drag")
        XCTAssertFalse(resizes.isEmpty, "a PTY SIGWINCH fired mid-drag, not at release")
        XCTAssertEqual(resizes.last?.0, view.testingGridSize.cols, "the vote matches the live grid width")

        // Drain the off-main authoritative reflow + its explicit-transaction present hop.
        view.testingWaitForEmulatorIdle()
        let hop = expectation(description: "live reflow present hop")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 2)
        if let stats = view.testingLastRenderStats {
            XCTAssertGreaterThan(stats.presentScheduleNanos, 0,
                                 "the mid-drag present takes the transaction-synchronized path")
        }
    }

    func testLiveReflowDisabledDefersCommitToRelease() throws {
        // The escape hatch (real-time reflow off) must preserve the legacy contract end-to-end:
        // the grid stays put and no SIGWINCH fires until the drag ends. `makeHostedView` already
        // disables real-time reflow for the preview/legacy suite.
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        XCTAssertFalse(view.testingLiveResizeReflowEnabled)
        for i in 0 ..< 30 { view.receive("defer line \(i)\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        let startCols = view.testingGridSize.cols
        var resizes = 0
        view.onResize = { _, _ in resizes += 1 }

        view.viewWillStartLiveResize()
        var frame = window.frame
        frame.size.width += 40
        window.setFrame(frame, display: false)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.testingGridSize.cols, startCols, "escape hatch: the grid stays put mid-drag")
        XCTAssertEqual(resizes, 0, "escape hatch: no SIGWINCH mid-drag")

        view.viewDidEndLiveResize()
        XCTAssertNotEqual(view.testingGridSize.cols, startCols, "the settled size commits at release")
        XCTAssertGreaterThan(resizes, 0, "the SIGWINCH fires at release")
    }
}
