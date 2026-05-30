import Foundation
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessTerminalKit
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
    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HARNESS_BENCHMARKS"] == "1",
            "Set HARNESS_BENCHMARKS=1 to run performance benchmarks."
        )
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

    // MARK: - VT parser / emulator throughput

    func testVTParseThroughput256KiB() throws {
        try skipUnlessEnabled()
        let bytes = syntheticStream(targetBytes: 256 * 1024)
        measure {
            let term = TerminalEmulator(cols: 120, rows: 40)
            term.feed(bytes)
        }
    }

    // MARK: - readGrid snapshot cost (per-frame, per attached compositor client)

    func testReadGridSnapshotFullScreen() throws {
        try skipUnlessEnabled()
        let term = HarnessGridTerminal(cols: 200, rows: 60)!
        term.feed(syntheticStream(targetBytes: 128 * 1024))
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
        measure {
            guard var framed = try? IPCCodec.encode(envelope) else { return XCTFail("encode") }
            _ = try? IPCCodec.decodeRequest(from: &framed)
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
        measure {
            for i in 0 ..< 40 {
                comp.invalidate() // force a full frame, not a no-op diff
                _ = comp.render(panes: panes, status: "harness · bench \(i)")
            }
        }
    }
}
