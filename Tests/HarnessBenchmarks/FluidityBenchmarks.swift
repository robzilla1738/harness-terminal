import AppKit
import Metal
import XCTest
@testable import HarnessTerminalKit
import HarnessTerminalRenderer

/// Frame-pacing measurement for the two "feel" paths: live-resize drag and scrollback scrolling.
/// Measurement-only (prints JSON lines like the other benchmarks; no absolute-time gates) — the
/// structural reuse invariants are asserted deterministically in `LiveResizeTests` /
/// `ScrollReuseTests`. Window-hosted with a real Metal renderer; skips when unavailable.
///
/// READ THE COMPONENT LINES, NOT THE WALL-CLOCK TICK: these loops present far faster than a
/// display drains drawables, so with `maximumDrawableCount = 2` every tick blocks ~one vsync in
/// `nextDrawable()` — a pacing artifact of the headless tight loop, not main-thread cost (real
/// wheel/drag events arrive at display cadence, where the pool always has a free drawable).
/// The signal is `encode` (CPU per tick), `encodedRowsPerTick`/`meanEncodedRows` (reuse health:
/// 0 on sub-cell drag ticks and fraction-only scroll ticks), and `schedule_wait` (the
/// transaction-synchronized present's bounded stall). On-hardware truth: Scripts/measure-fluidity.sh.
@MainActor
final class FluidityBenchmarks: XCTestCase {
    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARNESS_BENCHMARKS"] == "1",
            "Set HARNESS_BENCHMARKS=1 to run performance benchmarks."
        )
    }

    private func makeHostedView(in window: NSWindow) throws -> HarnessTerminalSurfaceView {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        window.contentView = view
        guard view.testingHasRenderer else { throw XCTSkip("renderer unavailable") }
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func percentileLine(_ name: String, samples: [UInt64], fields: [(String, String)] = []) {
        let p = FrameSignposter.percentilesMicros(samples)
        let extras = fields.map { ",\"\($0.0)\":\($0.1)" }.joined()
        print("{\"benchmark\":\"\(name)\",\"p50us\":\(p.p50),\"p95us\":\(p.p95),\"maxus\":\(p.max),\"ticks\":\(samples.count)\(extras)}")
    }

    func testLiveResizeDragFramePacing() throws {
        try skipUnlessEnabled()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        var lastStats: TerminalRenderStats?
        view.onRenderStats = { lastStats = $0 }

        for i in 0 ..< 300 { view.receive("content line \(i) abcdefghijklmnopqrstuvwxyz\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard lastStats != nil else { throw XCTSkip("no present happened (drawable unavailable)") }

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }

        // Synthetic drag: 1px-wide steps so most ticks stay inside one cell column (the pure
        // sub-cell repaint case) and a few cross a boundary (the preview-reflow case). The grid
        // commit is debounced to drag-end, so the boundary signal is the *preview* changing the
        // built frame's cell count, not `testingGridSize`.
        var tickNanos: [UInt64] = []
        var subCellTicks: [UInt64] = []
        var boundaryTicks: [UInt64] = []
        var subCellEncodedRows: [Int] = []
        var scheduleNanos: [UInt64] = []
        var encodeNanos: [UInt64] = []
        var semaphoreNanos: [UInt64] = []
        var uploadBytes: [Int] = []
        var cellsBefore = lastStats?.cells ?? 0
        for _ in 0 ..< 60 {
            var frame = window.frame
            frame.size.width += 1
            window.setFrame(frame, display: false)
            view.needsLayout = true
            lastStats = nil
            let start = DispatchTime.now().uptimeNanoseconds
            view.layoutSubtreeIfNeeded()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            tickNanos.append(elapsed)
            let cellsAfter = lastStats?.cells ?? cellsBefore
            if cellsAfter == cellsBefore {
                subCellTicks.append(elapsed)
                if let stats = lastStats { subCellEncodedRows.append(stats.encodedRows) }
            } else {
                boundaryTicks.append(elapsed)
            }
            if let stats = lastStats {
                scheduleNanos.append(stats.presentScheduleNanos)
                encodeNanos.append(stats.encodeNanos)
                semaphoreNanos.append(stats.semaphoreWaitNanos)
                uploadBytes.append(stats.instanceUploadBytes)
            }
            cellsBefore = cellsAfter
        }

        let encodedSummary = subCellEncodedRows.isEmpty
            ? "[]"
            : "[\(subCellEncodedRows.map(String.init).joined(separator: ","))]"
        percentileLine("fluidity_resize_tick", samples: tickNanos)
        percentileLine("fluidity_resize_tick_subcell", samples: subCellTicks,
                       fields: [("encodedRowsPerTick", encodedSummary)])
        percentileLine("fluidity_resize_tick_boundary", samples: boundaryTicks)
        percentileLine("fluidity_resize_schedule_wait", samples: scheduleNanos)
        percentileLine("fluidity_resize_encode", samples: encodeNanos)
        percentileLine("fluidity_resize_semaphore_wait", samples: semaphoreNanos)
        let meanUpload = uploadBytes.isEmpty ? 0 : uploadBytes.reduce(0, +) / uploadBytes.count
        print("{\"benchmark\":\"fluidity_resize_upload\",\"meanBytes\":\(meanUpload)}")
    }

    /// Boundary-crossing drag pacing: every tick steps a FULL cell column, so each one carries a
    /// real re-wrap (the 1px loop above crosses a boundary only every ~cellWidth ticks). Measures
    /// the two halves the async preview splits a boundary into: the layout tick's main-thread
    /// wall (must look like a sub-cell tick — the cached frame re-presented, zero rows), and the
    /// preview present that lands after the queue drains (the one cache-populating rebuild, with
    /// its `buildInstancesNanos`/`uploadNanos` split attributing the cost per value boundary).
    func testLiveResizeBoundaryCrossingPacing() throws {
        try skipUnlessEnabled()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        var lastStats: TerminalRenderStats?
        var lastPresentTick: UInt64 = 0 // captured IN the sink — the polling loop below has ~2ms
        view.onRenderStats = {          // granularity, which would otherwise swamp the land figure
            lastStats = $0
            lastPresentTick = DispatchTime.now().uptimeNanoseconds
        }

        for i in 0 ..< 300 { view.receive("boundary line \(i) abcdefghijklmnopqrstuvwxyz\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard lastStats != nil else { throw XCTSkip("no present happened (drawable unavailable)") }
        let cellPx = view.testingCellPixelSize.width
        guard cellPx > 0 else { throw XCTSkip("no cell metrics") }
        let scale = window.backingScaleFactor
        let stepPoints = ceil(CGFloat(cellPx) / max(1, scale)) // one full cell column per tick

        view.viewWillStartLiveResize()
        defer { view.viewDidEndLiveResize() }

        var layoutNanos: [UInt64] = []          // main wall of the boundary tick itself
        var layoutEncodedRows: [Int] = []       // 0 = cached re-present (the async-preview win)
        var previewBuildNanos: [UInt64] = []    // FrameBuilder full build (boundary 2)
        var previewInstanceNanos: [UInt64] = [] // CPU instance build (boundary 3)
        var previewUploadNanos: [UInt64] = []   // GPU upload (boundary 4)
        var previewUploadBytes: [Int] = []
        var previewLandNanos: [UInt64] = []     // tick start → re-wrapped frame on glass
        var commitFramesExcluded = 0
        for _ in 0 ..< 16 {
            var frame = window.frame
            frame.size.width += stepPoints
            window.setFrame(frame, display: false)
            view.needsLayout = true
            let cellsBefore = lastStats?.cells ?? 0
            let generationBefore = view.testingRenderGeneration
            lastStats = nil
            let start = DispatchTime.now().uptimeNanoseconds
            view.layoutSubtreeIfNeeded()
            layoutNanos.append(DispatchTime.now().uptimeNanoseconds &- start)
            if let s = lastStats { layoutEncodedRows.append(s.encodedRows) }
            // Drain the async preview: emulator-queue build, then the main hop that presents it.
            view.testingWaitForEmulatorIdle()
            let deadline = Date().addingTimeInterval(1)
            while (lastStats?.cells ?? cellsBefore) == cellsBefore, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            guard let s = lastStats, s.cells != cellsBefore else { continue } // dropped (no drawable)
            // Exclude commit frames: if the drain outlived the 60ms debounce, the landed frame is
            // the AUTHORITATIVE reflow (generation bumped), not the preview — its O(history) cost
            // must not pollute the preview percentiles.
            let target = view.testingPreviewTarget
            guard view.testingRenderGeneration == generationBefore,
                  s.cells == target.cols * target.rows else {
                commitFramesExcluded += 1
                continue
            }
            previewLandNanos.append(lastPresentTick &- start)
            previewBuildNanos.append(s.frameBuildNanos)
            previewInstanceNanos.append(s.buildInstancesNanos)
            previewUploadNanos.append(s.uploadNanos)
            previewUploadBytes.append(s.instanceUploadBytes)
        }

        let encodedSummary = layoutEncodedRows.isEmpty
            ? "[]" : "[\(layoutEncodedRows.map(String.init).joined(separator: ","))]"
        percentileLine("fluidity_resize_boundary_main", samples: layoutNanos,
                       fields: [("encodedRowsPerTick", encodedSummary)])
        percentileLine("fluidity_resize_boundary_land", samples: previewLandNanos)
        percentileLine("fluidity_resize_boundary_framebuild", samples: previewBuildNanos)
        percentileLine("fluidity_resize_boundary_instancebuild", samples: previewInstanceNanos)
        percentileLine("fluidity_resize_boundary_upload", samples: previewUploadNanos)
        let meanBytes = previewUploadBytes.isEmpty
            ? 0 : previewUploadBytes.reduce(0, +) / previewUploadBytes.count
        print("{\"benchmark\":\"fluidity_resize_boundary_upload_bytes\",\"meanBytes\":\(meanBytes),\"ticks\":\(previewUploadBytes.count),\"commitFramesExcluded\":\(commitFramesExcluded)}")
    }

    func testScrollTickFramePacing() throws {
        try skipUnlessEnabled()
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device available") }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil }
        let view = try makeHostedView(in: window)
        var lastStats: TerminalRenderStats?
        view.onRenderStats = { lastStats = $0 }

        for i in 0 ..< 500 { view.receive("history line \(i) abcdefghijklmnopqrstuvwxyz\r\n") }
        view.testingWaitForEmulatorIdle()
        view.testingForceRender()
        guard lastStats != nil else { throw XCTSkip("no present happened (drawable unavailable)") }

        var tickNanos: [UInt64] = []
        var encodedRows: [Int] = []
        for _ in 0 ..< 80 {
            lastStats = nil
            let start = DispatchTime.now().uptimeNanoseconds
            view.testingScrollBy(lines: 1)
            view.testingForceRender()
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            tickNanos.append(elapsed)
            if let stats = lastStats { encodedRows.append(stats.encodedRows) }
        }

        let meanEncoded = encodedRows.isEmpty
            ? 0.0 : Double(encodedRows.reduce(0, +)) / Double(encodedRows.count)
        percentileLine("fluidity_scroll_tick", samples: tickNanos,
                       fields: [("meanEncodedRows", String(format: "%.2f", meanEncoded))])

        // Pixel-smooth fraction ticks: sub-line advances that stay inside one integer line —
        // the dominant tick during trackpad scrolling. Should be uniform-only (0 encoded rows).
        // Park mid-line first so the ±0.2 jiggle never crosses the ceil boundary (an integer
        // crossing takes the async shift path and wouldn't be measured here).
        view.testingScrollByContinuous(lines: 0.5)
        view.testingForceRender() // settle + establish repaint coherence at the parked offset
        var fractionTickNanos: [UInt64] = []
        var fractionEncodedRows: [Int] = []
        var fractionPresents = 0
        for i in 0 ..< 80 {
            lastStats = nil
            let start = DispatchTime.now().uptimeNanoseconds
            view.testingScrollByContinuous(lines: i % 2 == 0 ? 0.2 : -0.2)
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            fractionTickNanos.append(elapsed)
            if let stats = lastStats {
                fractionPresents += 1
                fractionEncodedRows.append(stats.encodedRows)
            }
        }
        let meanFractionEncoded = fractionEncodedRows.isEmpty
            ? 0.0 : Double(fractionEncodedRows.reduce(0, +)) / Double(fractionEncodedRows.count)
        percentileLine("fluidity_scroll_fraction_tick", samples: fractionTickNanos,
                       fields: [("meanEncodedRows", String(format: "%.2f", meanFractionEncoded)),
                                ("presents", String(fractionPresents))])
    }
}
