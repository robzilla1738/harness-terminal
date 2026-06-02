import Foundation
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessTerminalRenderer
@testable import HarnessTerminalKit
import HarnessTheme
import Metal
import XCTest

/// Performance baselines for Harness's hot paths. These exist to catch regressions, not to
/// gate CI — `measure {}` runs each body ~10×, which is too slow for the default suite, so the
/// whole file is opt-in. Run with:
///
///     HARNESS_BENCHMARKS=1 swift test --filter HarnessBenchmarks
///
/// Xcode/`xctest` prints the per-iteration time and tracks it against a stored baseline.
///
/// Workloads are sized to finish quickly even in an unoptimized debug build (`measure {}` runs
/// each body ~10×). For headline absolute numbers, build release: `swift test -c release
/// --filter HarnessBenchmarks` (still gated on HARNESS_BENCHMARKS=1).
final class PerformanceBenchmarks: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARNESS_BENCHMARKS"] == "1",
            "Set HARNESS_BENCHMARKS=1 to run performance benchmarks."
        )
    }

    private func timedNanos(_ body: () -> Void) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return DispatchTime.now().uptimeNanoseconds &- start
    }

    private func printBenchmark(_ name: String, nanos: UInt64, fields: [(String, String)] = []) {
        let extras = fields.map { ",\"\($0.0)\":\($0.1)" }.joined()
        print("{\"benchmark\":\"\(name)\",\"nanos\":\(nanos)\(extras)}")
    }

    private func makeMetalDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        return device
    }

    private func makeTarget(_ device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: TerminalMetalRenderer.pixelFormat, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    private func filledSnapshot(cols: Int, rows: Int) -> TerminalGridSnapshot {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        let chunk = "abcdefghijklmnopqrstuvwxyz0123456789"
        var stream = "\u{1b}[?25l"
        for row in 0 ..< rows {
            var line = ""
            while line.count < cols { line += chunk }
            let color = 31 + (row % 7)
            let background = 40 + (row % 8)
            stream += "\u{1b}[\(row + 1);1H\u{1b}[\(color);\(background)m\(String(line.prefix(cols)))"
        }
        term.feed(stream)
        return term.readGrid()!
    }

    private func frame(cols: Int, rows: Int) -> TerminalFrame {
        FrameBuilder(theme: theme).build(filledSnapshot(cols: cols, rows: rows))
    }

    private func makeAtlas(device: MTLDevice, rasterizer: GlyphRasterizer? = nil) throws -> GlyphAtlas {
        let rasterizer = rasterizer ?? GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        return try XCTUnwrap(GlyphAtlas(device: device, rasterizer: rasterizer), "GlyphAtlas failed to build")
    }

    @discardableResult
    private func encodeAndWait(
        renderer: TerminalMetalRenderer,
        frame: TerminalFrame,
        target: MTLTexture,
        damage: TerminalDamage? = nil
    ) -> TerminalRenderStats {
        guard let commandBuffer = renderer.encode(
            frame,
            target: target,
            clearColor: RenderColor(red: 0, green: 0, blue: 0, alpha: 1),
            origin: (0, 0),
            gamma: 1,
            ligatures: false,
            damage: damage
        ) else {
            XCTFail("encode")
            return renderer.stats
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return renderer.stats
    }

    /// A representative ~1 MiB stream: colored SGR runs, cursor moves, newlines, and UTF-8 —
    /// the kind of output a build log or a TUI produces.
    private func syntheticStream(targetBytes: Int) -> [UInt8] {
        var s = ""
        var i = 0
        while s.utf8.count < targetBytes {
            let color = 31 + (i % 7)
            s += "\u{1b}[\(color);1mline \(i)\u{1b}[0m: the quick brown fox — café ☕ 0123456789\r\n"
            if i % 24 == 23 { s += "\u{1b}[2J\u{1b}[H" } // periodic clear+home, like a redraw
            i += 1
        }
        return Array(s.utf8)
    }

    private struct SurfaceMainThreadStallSample {
        var totalNanos: UInt64
        var feedNanos: UInt64
        var frameBuildNanos: UInt64
        var bytes: Int
        var cells: Int
        var historyLines: Int
    }

    /// Mirrors today's surface hot path: PTY bytes are parsed on the main thread, then the next
    /// frame snapshot/damage/build is also produced on the main thread. This is Task 8's gate:
    /// if this number is not a real stall, the off-main pipeline should not be enabled.
    @MainActor
    private func sampleSurfaceMainThreadStall(bytes: [UInt8], cols: Int = 160, rows: Int = 48) -> SurfaceMainThreadStallSample {
        let term = TerminalEmulator(cols: cols, rows: rows)
        term.maxScrollbackLines = 10_000
        let builder = FrameBuilder(theme: theme)

        let start = DispatchTime.now().uptimeNanoseconds
        let feedStart = DispatchTime.now().uptimeNanoseconds
        term.feed(bytes)
        let feedNanos = DispatchTime.now().uptimeNanoseconds &- feedStart

        let frameBuildStart = DispatchTime.now().uptimeNanoseconds
        let grid = term.readGrid()
        let damage = term.consumeDamage()
        let frame = builder.build(grid, region: nil, imageProvider: { _ in nil }, reusing: nil, damage: damage)
        let frameBuildNanos = DispatchTime.now().uptimeNanoseconds &- frameBuildStart

        return SurfaceMainThreadStallSample(
            totalNanos: DispatchTime.now().uptimeNanoseconds &- start,
            feedNanos: feedNanos,
            frameBuildNanos: frameBuildNanos,
            bytes: bytes.count,
            cells: frame.cells.count,
            historyLines: term.historyCount
        )
    }

    private struct SurfaceOffMainStallSample {
        var mainNanos: UInt64
        var workerDrainNanos: UInt64
        var bytes: Int
        var cells: Int
    }

    @MainActor
    private func sampleSurfaceOffMainStall(data: Data) -> SurfaceOffMainStallSample {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        view.testingResizeGrid(cols: 160, rows: 48)

        let mainStart = DispatchTime.now().uptimeNanoseconds
        view.receive(data)
        let mainNanos = DispatchTime.now().uptimeNanoseconds &- mainStart

        let workerStart = DispatchTime.now().uptimeNanoseconds
        view.testingWaitForEmulatorIdle()
        let workerDrainNanos = DispatchTime.now().uptimeNanoseconds &- workerStart

        let grid = view.testingReadGridSnapshot()
        return SurfaceOffMainStallSample(
            mainNanos: mainNanos,
            workerDrainNanos: workerDrainNanos,
            bytes: data.count,
            cells: grid.cols * grid.rows
        )
    }

    // MARK: - Consumer scoreboard (faithful end-to-end: bytes → parsed grid → built frame)
    //
    // The cross-terminal `os.write` drain benchmark (Scripts/benchmarks/terminal_stress_runner.py)
    // is NOT a faithful measure of the VT engine: with no consumer→writer backpressure, drain is
    // gated by the daemon PTY-read loop + leftover CPU after the GUI renders, so it swings ~30% on
    // window focus alone and can move *opposite* to engine speed. This scoreboard instead measures
    // the GUI's actual consumer work — parse + readGrid + damage + FrameBuilder.build — on the same
    // seven workloads, in-process and deterministic. Higher MB/s = the terminal turns bytes into a
    // renderable frame faster. THIS is the scoreboard for the parse/width/cell/scroll hot paths.

    /// The seven cross-terminal workloads as in-process byte payloads (mirroring the structure of
    /// `terminal_stress_runner.py`), sized for a fast micro-benchmark.
    private func scoreboardWorkloads() -> [(name: String, bytes: [UInt8])] {
        let target = 1024 * 1024
        var out: [(String, [UInt8])] = []

        var plain = ""
        while plain.utf8.count < target { plain += "the quick brown fox jumps over the lazy dog 0123456789\r\n" }
        out.append(("plain_ascii", Array(plain.utf8)))

        let colors = [31, 32, 33, 34, 35, 36, 37, 90, 91, 92, 93, 94, 95, 96, 97]
        var sgr = ""; var i = 0
        while sgr.utf8.count < target {
            sgr += "\u{1b}[\(colors[i % colors.count]);1mline \(String(format: "%06d", i))\u{1b}[0m build output with SGR color and ASCII payload 0123456789\r\n"
            i += 1
        }
        out.append(("ansi_sgr", Array(sgr.utf8)))

        let sample = "é Ω 世 Ж 中 λ ✓ café résumé 漢字 emoji-free wide text "
        var uni = ""; i = 0
        while uni.utf8.count < target { uni += "\(String(format: "%06d", i)) \(sample)\(sample)\r\n"; i += 1 }
        out.append(("unicode_mixed", Array(uni.utf8)))

        let av = ["\u{1b}[1m", "\u{1b}[2m", "\u{1b}[3m", "\u{1b}[4m", "\u{1b}[7m", "\u{1b}[9m", "\u{1b}[53m"]
        var attrs = ""; i = 0
        while attrs.utf8.count < target {
            attrs += av[i % av.count] + "attribute row \(String(format: "%06d", i)) underline bold faint inverse strike overline\u{1b}[0m\r\n"
            i += 1
        }
        out.append(("attributes", Array(attrs.utf8)))

        var tc = ""
        for frame in 0 ..< 300 {
            tc += "\u{1b}[H"
            for col in 0 ..< 160 {
                let r = (col * 255) / 159, g = (frame * 7) % 256, b = 255 - r
                tc += "\u{1b}[48;2;\(r);\(g);\(b)m "
            }
            tc += "\u{1b}[0m\r\n"
        }
        out.append(("truecolor_gradient", Array(tc.utf8)))

        let alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let base = String(String(repeating: alphabet, count: 4).prefix(160))
        var redraw = ""
        for frame in 0 ..< 300 {
            redraw += "\u{1b}[H"
            for row in 0 ..< 48 { redraw += "\u{1b}[\(31 + ((row + frame) % 7))m\(base)\u{1b}[0m\r\n" }
        }
        out.append(("redraw", Array(redraw.utf8)))

        var sb = ""
        for j in 0 ..< 20_000 { sb += "scrollback row \(String(format: "%06d", j)) xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\r\n" }
        out.append(("scrollback", Array(sb.utf8)))

        return out
    }

    /// Faithful consumer throughput per workload: parse + frame build, in-process, no daemon or
    /// render contention. Emits `consumer_<workload>` with nanos + MB/s + the feed/frame-build split.
    @MainActor
    func testConsumerScoreboard() throws {
        try skipUnlessEnabled()
        for (name, bytes) in scoreboardWorkloads() {
            let sample = sampleSurfaceMainThreadStall(bytes: bytes)
            let mbps = (Double(bytes.count) / 1_000_000) / (Double(sample.totalNanos) / 1_000_000_000)
            printBenchmark("consumer_\(name)", nanos: sample.totalNanos, fields: [
                ("bytes", "\(bytes.count)"),
                ("mbps", String(format: "%.3f", mbps)),
                ("feedNanos", "\(sample.feedNanos)"),
                ("frameBuildNanos", "\(sample.frameBuildNanos)"),
            ])
        }
    }

    // MARK: - Latency under load (the headline gate for the daemon→GUI consume path)
    //
    // What users feel under a flood is *backlog drain time*: a keystroke echo is in-band (queued in
    // the PTY behind the flooding program's bytes), so echo latency ≈ how fast the consume path
    // turns the backlog into frames — i.e. throughput. This drives the *real* off-main consume path
    // (`HarnessTerminalSurfaceView.receive` → emulator worker hop → main hop → scheduler) with a
    // chunked flood and reports: `mbps` (drain throughput — the latency proxy), `mainHops` (how well
    // the path coalesces a small-chunk storm — the lever Tier 1 moves), and `mainGap*` (the longest
    // the main thread is occupied between two consecutive runloop turns — i.e. how free the UI stays
    // to service a keystroke; the off-main pipeline is supposed to keep this tiny). Deterministic,
    // in-process: no daemon, socket, or window-focus confound.

    private func chunked(_ bytes: [UInt8], size: Int) -> [Data] {
        var out: [Data] = []
        var i = 0
        while i < bytes.count {
            let end = min(i + size, bytes.count)
            out.append(Data(bytes[i ..< end]))
            i = end
        }
        return out
    }

    private func percentile(_ sorted: [UInt64], _ p: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    /// A sustained ~4 MiB flood of SGR-punctuated + mixed-width-Unicode output — the shape that a
    /// build log / chatty TUI produces, and the workloads Harness trails Ghostty on.
    private func floodPayload(targetBytes: Int = 4 * 1024 * 1024) -> [UInt8] {
        let colors = [31, 32, 33, 34, 35, 36, 91, 92, 93, 94, 95, 96]
        let uni = "café résumé Ω 世 中 λ ✓ "
        var s = ""; var i = 0
        while s.utf8.count < targetBytes {
            s += "\u{1b}[\(colors[i % colors.count]);1mline \(String(format: "%07d", i))\u{1b}[0m \(uni)build output 0123456789\r\n"
            i += 1
        }
        return Array(s.utf8)
    }

    /// Headline gate: drives a 4 MiB flood through the real off-main surface at a small-chunk size
    /// (storm) and the daemon's 64 KiB read size. Emits `consume_latency_under_load_<chunkBytes>`
    /// with drain throughput (the echo-latency proxy), the coalescing hop count, and the worst
    /// main-thread occupancy between runloop turns (UI freedom under load).
    @MainActor
    func testConsumeLatencyUnderLoad() throws {
        try skipUnlessEnabled()
        let flood = floodPayload()
        for chunkSize in [4 * 1024, 64 * 1024] {
            let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
            view.testingResizeGrid(cols: 160, rows: 48)
            view.testingMainHopCount = 0

            let chunks = chunked(flood, size: chunkSize)
            let probeEvery = max(1, chunks.count / 64)
            // Each probe records the wall-clock instant the runloop reaches it; the gap between two
            // consecutive probe runs is the main thread's busy span in between (worst-case = the
            // longest a just-arrived keystroke would wait for the main thread).
            var probeRuns: [UInt64] = []
            let exp = expectation(description: "drain-\(chunkSize)")

            let start = DispatchTime.now().uptimeNanoseconds
            for (idx, chunk) in chunks.enumerated() {
                view.receive(chunk)
                if idx % probeEvery == 0 {
                    DispatchQueue.main.async { probeRuns.append(DispatchTime.now().uptimeNanoseconds) }
                }
            }
            // Drain the parser worker (sync barrier), then a sentinel that runs behind every
            // flood-produced main bounce + probe, so the runloop fully settles before we measure.
            view.testingWaitForEmulatorIdle()
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 60)
            let totalNanos = DispatchTime.now().uptimeNanoseconds &- start

            var gaps: [UInt64] = []
            gaps.reserveCapacity(max(0, probeRuns.count - 1))
            for k in 1 ..< max(1, probeRuns.count) { gaps.append(probeRuns[k] &- probeRuns[k - 1]) }
            let sortedGaps = gaps.sorted()
            let mbps = (Double(flood.count) / 1_000_000) / (Double(totalNanos) / 1_000_000_000)
            printBenchmark("consume_latency_under_load_\(chunkSize)", nanos: totalNanos, fields: [
                ("bytes", "\(flood.count)"),
                ("chunks", "\(chunks.count)"),
                ("mbps", String(format: "%.3f", mbps)),
                ("mainHops", "\(view.testingMainHopCount)"),
                ("mainGapP50Nanos", "\(percentile(sortedGaps, 0.50))"),
                ("mainGapP95Nanos", "\(percentile(sortedGaps, 0.95))"),
                ("mainGapMaxNanos", "\(sortedGaps.last ?? 0)"),
            ])
        }
    }

    // MARK: - VT parser / emulator throughput

    func testVTParseThroughput256KiB() throws {
        try skipUnlessEnabled()
        let bytes = syntheticStream(targetBytes: 256 * 1024)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
        printBenchmark("vt_parse_throughput_256kib", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
    }

    @MainActor
    func testSurfaceMainThreadStall4MiB() throws {
        try skipUnlessEnabled()
        let bytes = syntheticStream(targetBytes: 4 * 1024 * 1024)
        let sample = sampleSurfaceMainThreadStall(bytes: bytes)
        XCTAssertEqual(sample.cells, 160 * 48)
        printBenchmark(
            "surface_main_thread_stall_4mib",
            nanos: sample.totalNanos,
            fields: [
                ("feedNanos", "\(sample.feedNanos)"),
                ("frameBuildNanos", "\(sample.frameBuildNanos)"),
                ("bytes", "\(sample.bytes)"),
                ("cells", "\(sample.cells)"),
                ("historyLines", "\(sample.historyLines)"),
            ]
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = sampleSurfaceMainThreadStall(bytes: bytes)
        }
    }

    @MainActor
    func testSurfaceOffMainMainThreadStall4MiB() throws {
        try skipUnlessEnabled()
        let data = Data(syntheticStream(targetBytes: 4 * 1024 * 1024))
        let sample = sampleSurfaceOffMainStall(data: data)
        XCTAssertEqual(sample.cells, 160 * 48)
        printBenchmark(
            "surface_off_main_thread_stall_4mib",
            nanos: sample.mainNanos,
            fields: [
                ("workerDrainNanos", "\(sample.workerDrainNanos)"),
                ("bytes", "\(sample.bytes)"),
                ("cells", "\(sample.cells)"),
            ]
        )

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            _ = sampleSurfaceOffMainStall(data: data)
        }
    }

    /// Pure printable-ASCII lines + CRLF — the best case for the ASCII run fast path (no escapes,
    /// no high bytes, so the parser batches each line into one run).
    private func asciiStream(targetBytes: Int) -> [UInt8] {
        var s = ""
        var i = 0
        while s.utf8.count < targetBytes {
            s += "line \(i): the quick brown fox jumps over the lazy dog 0123456789\r\n"
            i += 1
        }
        return Array(s.utf8)
    }

    /// SGR-colored ASCII: escapes punctuate the stream, but the text between them is printable
    /// ASCII that still flows through the run fast path.
    private func ansiAsciiStream(targetBytes: Int) -> [UInt8] {
        var s = ""
        var i = 0
        while s.utf8.count < targetBytes {
            let color = 31 + (i % 7)
            s += "\u{1b}[\(color);1mline \(i)\u{1b}[0m the quick brown fox jumps 0123456789\r\n"
            i += 1
        }
        return Array(s.utf8)
    }

    /// Print-dominated ASCII: no newlines, so it wraps to fill a tall screen instead of scrolling
    /// (scroll is O(cols×rows) per line and would otherwise mask the print cost the fast path
    /// targets).
    private func wrapStream(targetBytes: Int) -> [UInt8] {
        var a = [UInt8](); a.reserveCapacity(targetBytes)
        let chunk = Array("the quick brown fox jumps over the lazy dog 0123456789 ".utf8)
        while a.count < targetBytes { a.append(contentsOf: chunk) }
        return a
    }

    /// Mixed-width Unicode: Latin-1 accents, Greek, Cyrillic, CJK, and symbols — the per-scalar
    /// width-lookup workload. Mirrors the cross-terminal `unicode_mixed` payload.
    private func unicodeMixedStream(targetBytes: Int) -> [UInt8] {
        let sample = "é Ω 世 Ж 中 λ ✓ café résumé 漢字 emoji-free wide text "
        var s = ""
        var i = 0
        while s.utf8.count < targetBytes {
            s += "\(i): \(sample)\(sample)\r\n"
            i += 1
        }
        return Array(s.utf8)
    }

    /// SGR attribute storm: a fresh text-style escape each line then a reset, so the parser builds
    /// and dispatches CSI parameters constantly. Mirrors the cross-terminal `attributes` payload.
    private func sgrAttributeStormStream(targetBytes: Int) -> [UInt8] {
        let attrs = ["\u{1b}[1m", "\u{1b}[2m", "\u{1b}[3m", "\u{1b}[4m", "\u{1b}[7m", "\u{1b}[9m", "\u{1b}[53m"]
        var s = ""
        var i = 0
        while s.utf8.count < targetBytes {
            s += attrs[i % attrs.count] + "attribute row \(i) underline bold faint inverse strike overline\u{1b}[0m\r\n"
            i += 1
        }
        return Array(s.utf8)
    }

    /// Parse + write 256 KiB of plain ASCII — exercises the printable-ASCII run fast path.
    func testVTParsePlainASCII256KiB() throws {
        try skipUnlessEnabled()
        let bytes = asciiStream(targetBytes: 256 * 1024)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
        printBenchmark("vt_parse_plain_ascii_256kib", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
    }

    /// Parse + write 256 KiB of ANSI-colored ASCII — runs of ASCII between SGR escapes.
    func testVTParseAnsiColoredASCII256KiB() throws {
        try skipUnlessEnabled()
        let bytes = ansiAsciiStream(targetBytes: 256 * 1024)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
        printBenchmark("vt_parse_ansi_colored_ascii_256kib", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
    }

    /// Mixed-width Unicode — stresses the per-scalar `CharacterWidth.width(of:)` lookup, the path
    /// behind the `unicode_mixed` cross-terminal loss. Gates the O(1) width-table optimization.
    func testVTParseUnicodeMixed512KiB() throws {
        try skipUnlessEnabled()
        let bytes = unicodeMixedStream(targetBytes: 512 * 1024)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
        printBenchmark("vt_parse_unicode_mixed_512kib", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
    }

    /// SGR attribute storm — constant CSI build/dispatch. Gates the allocation-free param parsing;
    /// a regression to per-sequence nested-array allocation shows here. Maps to `attributes`.
    func testVTParseSGRAttributeStorm512KiB() throws {
        try skipUnlessEnabled()
        let bytes = sgrAttributeStormStream(targetBytes: 512 * 1024)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
        printBenchmark("vt_parse_sgr_attribute_storm_512kib", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
    }

    /// Region-scroll storm on the alternate screen (no history copy) — every line past the first
    /// screenful scrolls the 160×48 region. Gates the block-move scroll (C1); a regression to the
    /// per-cell nested-loop shift shows here.
    func testCellScrollRegion160x48() throws {
        try skipUnlessEnabled()
        var s = "\u{1b}[?1049h" // alternate screen: isolate the in-region scroll from scrollback
        for i in 0 ..< 5_000 { s += "scroll line \(i) with trailing content to fill the row\r\n" }
        let bytes = Array(s.utf8)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 160, rows: 48)
            term.feed(bytes)
        }
        printBenchmark("cell_scroll_region_160x48", nanos: nanos, fields: [("lines", "5000")])
        measure {
            let term = TerminalEmulator(cols: 160, rows: 48)
            term.feed(bytes)
        }
    }

    /// The run fast path on print-heavy ASCII. Compare against
    /// `testVTParseScalarBaselinePrintHeavyASCII` (same bytes, per-byte scalar path) to see the
    /// speedup directly — the run path is measurably faster here (scalar ≈ 1.3× the time, release).
    func testVTParseRunPathPrintHeavyASCII() throws {
        try skipUnlessEnabled()
        let bytes = wrapStream(targetBytes: 1024 * 1024)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 120, rows: 10_000)
            term.feed(bytes)
        }
        printBenchmark("vt_parse_run_path_print_heavy_ascii", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 120, rows: 10_000)
            term.feed(bytes)
        }
    }

    /// Baseline for `testVTParseRunPathPrintHeavyASCII`: identical input driven one byte at a time
    /// through the scalar path (no run batching), so the two measured averages bracket the win.
    func testVTParseScalarBaselinePrintHeavyASCII() throws {
        try skipUnlessEnabled()
        let bytes = wrapStream(targetBytes: 1024 * 1024)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 120, rows: 10_000)
            term.feedScalarwise(bytes)
        }
        printBenchmark("vt_parse_scalar_baseline_print_heavy_ascii", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 120, rows: 10_000)
            term.feedScalarwise(bytes)
        }
    }

    // MARK: - readGrid snapshot cost (per-frame, per attached compositor client)

    func testReadGridSnapshotFullScreen() throws {
        try skipUnlessEnabled()
        let term = HarnessGridTerminal(cols: 200, rows: 60)!
        term.feed(syntheticStream(targetBytes: 128 * 1024))
        let nanos = timedNanos {
            for _ in 0 ..< 40 { _ = term.readGrid() }
        }
        printBenchmark("read_grid_snapshot_full_screen", nanos: nanos, fields: [("cells", "\(200 * 60 * 40)")])
        measure {
            for _ in 0 ..< 40 { _ = term.readGrid() }
        }
    }

    // MARK: - Scrollback append + replay (steady state, at the cap)

    func testScrollbackSteadyStateAtCap() throws {
        try skipUnlessEnabled()
        // Feed well past the scrollback cap so eviction runs on most lines — the steady-state
        // hot path for a long-running shell. With amortized batch eviction this is ~O(1)/line;
        // a regression to per-line front-removal would be O(cap)/line and blow up here.
        var lines = ""
        for i in 0 ..< 6_000 { lines += "scrollback row \(i) with some trailing content\r\n" }
        let bytes = Array(lines.utf8)
        let nanos = timedNanos {
            let term = TerminalEmulator(cols: 80, rows: 24)
            term.maxScrollbackLines = 1_000
            term.feed(bytes)
            _ = term.readGrid(scrollbackOffset: 500)
        }
        printBenchmark("scrollback_steady_state_at_cap", nanos: nanos, fields: [("bytes", "\(bytes.count)")])
        measure {
            let term = TerminalEmulator(cols: 80, rows: 24)
            term.maxScrollbackLines = 1_000
            term.feed(bytes)
            _ = term.readGrid(scrollbackOffset: 500)
        }
    }

    // MARK: - IPC codec round trip (large capture-pane / sendData payload)

    func testIPCCodecRoundTrip4MiB() throws {
        try skipUnlessEnabled()
        let payload = Data(repeating: 0x41, count: 4 * 1024 * 1024)
        let envelope = IPCEnvelope(request: .sendData(surfaceID: UUID().uuidString, data: payload))
        let nanos = timedNanos {
            guard var framed = try? IPCCodec.encode(envelope) else { return XCTFail("encode") }
            _ = try? IPCCodec.decodeRequest(from: &framed)
        }
        printBenchmark("ipc_codec_round_trip_4mib", nanos: nanos, fields: [("bytes", "\(payload.count)")])
        measure {
            guard var framed = try? IPCCodec.encode(envelope) else { return XCTFail("encode") }
            _ = try? IPCCodec.decodeRequest(from: &framed)
        }
    }

    /// Change A: the PTY output path used to be `JSONEncoder` over `IPCReply(.data(...))`, which
    /// base64-encodes the bytes (+33% wire size) and spends JSON/base64 CPU both directions. The
    /// binary frame carries raw bytes with a 13-byte header. This benchmark prints the encode+decode
    /// time AND the wire size for both, so the win is a concrete number (CPU ratio + byte ratio).
    func testDataFrameEncodeVsJSONBase64Output() throws {
        try skipUnlessEnabled()
        // A typical busy-output read (post-Change-E PTY reads are up to 64 KiB).
        let payload = Data((0 ..< (64 * 1024)).map { UInt8($0 & 0xFF) })
        let sequence: UInt64 = 0xDEAD_BEEF

        let jsonNanos = timedNanos {
            guard let framed = try? IPCCodec.encode(IPCReply(response: .data(payload, sequence: sequence)))
            else { return XCTFail("json encode") }
            var buf = framed
            _ = try? IPCCodec.decodeReply(from: &buf)
        }
        let binaryNanos = timedNanos {
            guard let framed = try? IPCCodec.encodeOutputFrame(payload, sequence: sequence)
            else { return XCTFail("binary encode") }
            var buf = framed
            _ = try? IPCCodec.decodeReplyOrData(from: &buf)
        }
        let jsonWire = (try? IPCCodec.encode(IPCReply(response: .data(payload, sequence: sequence))))?.count ?? 0
        let binaryWire = (try? IPCCodec.encodeOutputFrame(payload, sequence: sequence))?.count ?? 0

        printBenchmark("data_frame_json_base64", nanos: jsonNanos, fields: [
            ("payload", "\(payload.count)"), ("wire", "\(jsonWire)"),
        ])
        printBenchmark("data_frame_binary", nanos: binaryNanos, fields: [
            ("payload", "\(payload.count)"), ("wire", "\(binaryWire)"),
            ("cpu_vs_json", String(format: "%.2fx", Double(jsonNanos) / Double(max(binaryNanos, 1)))),
            ("wire_vs_json", String(format: "%.2fx", Double(jsonWire) / Double(max(binaryWire, 1)))),
        ])
        // Guardrails (not perf gates): the binary frame must be smaller and no slower than JSON.
        XCTAssertLessThan(binaryWire, jsonWire, "binary frame must be smaller on the wire than JSON+base64")
        XCTAssertLessThanOrEqual(binaryWire, payload.count + 64, "binary frame is raw bytes + a tiny header")
    }

    /// The daemon→subscriber output-frame encode (`encodeOutputFrame`) over a 16 MiB stream of
    /// 64 KiB chunks — the per-chunk fixed cost on the transport floor. A regression here (extra
    /// copy / realloc) raises that floor for every workload.
    func testTransportOutputFrameEncode() throws {
        try skipUnlessEnabled()
        let payload = Data(repeating: 0x41, count: 64 * 1024)
        let iterations = 256 // ≈16 MiB through the encode path
        let nanos = timedNanos {
            for i in 0 ..< iterations {
                _ = try? IPCCodec.encodeOutputFrame(payload, sequence: UInt64(i) &* 65_536)
            }
        }
        printBenchmark("transport_output_frame_encode", nanos: nanos, fields: [
            ("bytes", "\(payload.count * iterations)"), ("frames", "\(iterations)"),
        ])
        measure {
            for i in 0 ..< iterations {
                _ = try? IPCCodec.encodeOutputFrame(payload, sequence: UInt64(i) &* 65_536)
            }
        }
    }

    // MARK: - Compositor frame build (split layout → diffed ANSI)

    func testCompositorFrameBuildFourPanes() throws {
        try skipUnlessEnabled()
        func snapshot(_ cols: Int, _ rows: Int) -> TerminalGridSnapshot {
            let t = HarnessGridTerminal(cols: cols, rows: rows)!
            t.feed("\u{1b}[32mpane content\u{1b}[0m\r\n" + String(repeating: "x", count: cols * 2))
            return t.readGrid()!
        }
        let comp = GridCompositor(cols: 160, rows: 48)
        let g = snapshot(79, 23)
        let panes = [
            CompositorPane(rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: 0, y: 0, cols: 79, rows: 23), grid: g, isActive: true),
            CompositorPane(rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: 81, y: 0, cols: 79, rows: 23), grid: g, isActive: false),
            CompositorPane(rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: 0, y: 25, cols: 79, rows: 23), grid: g, isActive: false),
            CompositorPane(rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: 81, y: 25, cols: 79, rows: 23), grid: g, isActive: false),
        ]
        let nanos = timedNanos {
            for i in 0 ..< 40 {
                comp.invalidate()
                _ = comp.render(panes: panes, status: "harness · bench \(i)")
            }
        }
        printBenchmark("compositor_frame_build_four_panes", nanos: nanos, fields: [("panes", "4"), ("frames", "40")])
        measure {
            for i in 0 ..< 40 {
                comp.invalidate() // force a full frame, not a no-op diff
                _ = comp.render(panes: panes, status: "harness · bench \(i)")
            }
        }
    }

    // MARK: - Frame builder and renderer stats

    private func runFrameBuildBenchmark(name: String, cols: Int, rows: Int) throws {
        try skipUnlessEnabled()
        let snapshot = filledSnapshot(cols: cols, rows: rows)
        let builder = FrameBuilder(theme: theme)
        let nanos = timedNanos {
            _ = builder.build(snapshot)
        }
        printBenchmark(name, nanos: nanos, fields: [("cells", "\(cols * rows)")])
        measure {
            _ = builder.build(snapshot)
        }
    }

    func testBuildFrame80x24() throws {
        try runFrameBuildBenchmark(name: "build_frame_80x24", cols: 80, rows: 24)
    }

    func testBuildFrame160x48() throws {
        try runFrameBuildBenchmark(name: "build_frame_160x48", cols: 160, rows: 48)
    }

    func testBuildFrame240x80() throws {
        try runFrameBuildBenchmark(name: "build_frame_240x80", cols: 240, rows: 80)
    }

    func testRenderEncodeStats160x48() throws {
        try skipUnlessEnabled()
        let device = try makeMetalDevice()
        let renderer = try XCTUnwrap(
            TerminalMetalRenderer(device: device, fontFamily: "Menlo", fontSize: 14, scale: 2),
            "TerminalMetalRenderer failed to build"
        )
        let frame = frame(cols: 160, rows: 48)
        let size = renderer.surfacePixelSize(columns: 160, rows: 48)
        let target = try XCTUnwrap(makeTarget(device, width: size.width, height: size.height), "no texture")

        let stats = encodeAndWait(renderer: renderer, frame: frame, target: target)
        printBenchmark(
            "render_encode_stats_160x48",
            nanos: stats.encodeNanos,
            fields: [
                ("cells", "\(stats.cells)"),
                ("bgInstances", "\(stats.bgInstances)"),
                ("bgSpans", "\(stats.bgSpans)"),
                ("bgCells", "\(stats.bgCells)"),
                ("glyphInstances", "\(stats.glyphInstances)"),
                ("decoInstances", "\(stats.decoInstances)"),
                ("imageInstances", "\(stats.imageInstances)"),
                ("atlasPages", "\(stats.atlasPages)"),
                ("encodedRows", "\(stats.encodedRows)"),
                ("reusedRows", "\(stats.reusedRows)"),
                ("instanceUploadBytes", "\(stats.instanceUploadBytes)"),
            ]
        )
        measure {
            encodeAndWait(renderer: renderer, frame: frame, target: target)
        }
    }

    func testRenderEncodeIncrementalDamage160x48() throws {
        try skipUnlessEnabled()
        let device = try makeMetalDevice()
        let renderer = try XCTUnwrap(
            TerminalMetalRenderer(device: device, fontFamily: "Menlo", fontSize: 14, scale: 2),
            "TerminalMetalRenderer failed to build"
        )
        let frame = frame(cols: 160, rows: 48)
        let size = renderer.surfacePixelSize(columns: 160, rows: 48)
        let target = try XCTUnwrap(makeTarget(device, width: size.width, height: size.height), "no texture")
        _ = encodeAndWait(
            renderer: renderer,
            frame: frame,
            target: target,
            damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< 48), full: true)
        )

        let dirtyOneRow = TerminalDamage(rows: IndexSet(integer: 12), full: false)
        let stats = encodeAndWait(renderer: renderer, frame: frame, target: target, damage: dirtyOneRow)
        printBenchmark(
            "render_encode_incremental_damage_160x48",
            nanos: stats.encodeNanos,
            fields: [
                ("cells", "\(stats.cells)"),
                ("bgInstances", "\(stats.bgInstances)"),
                ("glyphInstances", "\(stats.glyphInstances)"),
                ("encodedRows", "\(stats.encodedRows)"),
                ("reusedRows", "\(stats.reusedRows)"),
                ("instanceUploadBytes", "\(stats.instanceUploadBytes)"),
            ]
        )
        measure {
            encodeAndWait(renderer: renderer, frame: frame, target: target, damage: dirtyOneRow)
        }
    }

    func testRenderEncodeStableDamage160x48() throws {
        try skipUnlessEnabled()
        let device = try makeMetalDevice()
        let renderer = try XCTUnwrap(
            TerminalMetalRenderer(device: device, fontFamily: "Menlo", fontSize: 14, scale: 2),
            "TerminalMetalRenderer failed to build"
        )
        let frame = frame(cols: 160, rows: 48)
        let size = renderer.surfacePixelSize(columns: 160, rows: 48)
        let target = try XCTUnwrap(makeTarget(device, width: size.width, height: size.height), "no texture")
        _ = encodeAndWait(
            renderer: renderer,
            frame: frame,
            target: target,
            damage: TerminalDamage(rows: IndexSet(integersIn: 0 ..< 48), full: true)
        )
        _ = encodeAndWait(
            renderer: renderer,
            frame: frame,
            target: target,
            damage: TerminalDamage(rows: [], full: false)
        )

        let cleanDamage = TerminalDamage(rows: [], full: false)
        let stats = encodeAndWait(renderer: renderer, frame: frame, target: target, damage: cleanDamage)
        printBenchmark(
            "render_encode_stable_damage_160x48",
            nanos: stats.encodeNanos,
            fields: [
                ("cells", "\(stats.cells)"),
                ("bgInstances", "\(stats.bgInstances)"),
                ("glyphInstances", "\(stats.glyphInstances)"),
                ("encodedRows", "\(stats.encodedRows)"),
                ("reusedRows", "\(stats.reusedRows)"),
                ("instanceUploadBytes", "\(stats.instanceUploadBytes)"),
            ]
        )
        measure {
            encodeAndWait(renderer: renderer, frame: frame, target: target, damage: cleanDamage)
        }
    }

    // MARK: - Glyph atlas cache

    func testGlyphAtlasASCIIWarmPath() throws {
        try skipUnlessEnabled()
        let device = try makeMetalDevice()
        let atlas = try makeAtlas(device: device)
        let keys = (33 ... 126).map { GlyphKey(codepoint: UInt32($0), bold: false, italic: false) }
        for key in keys { _ = atlas.entry(for: key) }

        let before = atlas.stats
        let nanos = timedNanos {
            for _ in 0 ..< 200 {
                for key in keys { _ = atlas.entry(for: key) }
            }
        }
        let after = atlas.stats
        printBenchmark(
            "glyph_atlas_ascii_warm_path",
            nanos: nanos,
            fields: [
                ("entries", "\(after.entries)"),
                ("hits", "\(after.hits - before.hits)"),
                ("misses", "\(after.misses - before.misses)"),
                ("pages", "\(after.pages)"),
            ]
        )
        measure {
            for _ in 0 ..< 200 {
                for key in keys { _ = atlas.entry(for: key) }
            }
        }
    }

    func testGlyphAtlasMixedUnicodePath() throws {
        try skipUnlessEnabled()
        let device = try makeMetalDevice()
        let rasterizer = GlyphRasterizer(fontFamily: "Menlo", size: 14, scale: 2)
        let keys = "AéΩ世Ж中λ✓".unicodeScalars.map {
            GlyphKey(codepoint: $0.value, bold: false, italic: false)
        }
        func runLookups(_ atlas: GlyphAtlas) {
            for key in keys { _ = atlas.entry(for: key) }
            for key in keys { _ = atlas.entry(for: key) }
        }

        let atlas = try makeAtlas(device: device, rasterizer: rasterizer)
        let before = atlas.stats
        let nanos = timedNanos {
            runLookups(atlas)
        }
        let after = atlas.stats
        printBenchmark(
            "glyph_atlas_mixed_unicode_path",
            nanos: nanos,
            fields: [
                ("entries", "\(after.entries)"),
                ("hits", "\(after.hits - before.hits)"),
                ("misses", "\(after.misses - before.misses)"),
                ("pages", "\(after.pages)"),
            ]
        )
        measure {
            guard let atlas = GlyphAtlas(device: device, rasterizer: rasterizer) else {
                return XCTFail("GlyphAtlas failed to build")
            }
            runLookups(atlas)
        }
    }
}
