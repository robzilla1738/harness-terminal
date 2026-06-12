#if canImport(Darwin)
import Foundation
import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// End-to-end daemon echo RTT: client input frame → daemon → PTY write → kernel tty echo →
/// daemon read → output frame → client. This is the IPC + PTY half of input-to-photon that
/// `FrameSignposter`'s in-app `echo` percentiles include but the render benches don't — the
/// SCORECARD's missing daemon-side latency row. Pure measurement; double-gated like the PTY
/// drain ceiling bench (it boots a real in-process daemon and spawns `/bin/cat`).
final class EchoRTTBenchmark: XCTestCase {
    private var root: URL?
    private var previousHome: String?
    private var server: DaemonServer!

    private func skipUnlessEnabled() throws {
        _ = testSIGPIPEIgnored
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["HARNESS_BENCHMARKS"] == "1" && env["HARNESS_LIVE_DAEMON_TESTS"] == "1",
            "Set HARNESS_BENCHMARKS=1 and HARNESS_LIVE_DAEMON_TESTS=1 to run the echo RTT benchmark."
        )
    }

    override func setUpWithError() throws {
        try skipUnlessEnabled()
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        // Short root so the Unix socket path fits in sun_path (104 chars).
        let dir = URL(fileURLWithPath: "/tmp/hrtt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
        setenv("HARNESS_HOME", dir.path, 1)
        try HarnessPaths.ensureDirectories()
        server = DaemonServer()
        try server.start()
        let client = DaemonClient()
        let ready = waitUntil(timeout: 10) {
            if case .pong = (try? client.request(.ping, timeout: 0.4)) { return true }
            return false
        }
        if !ready { XCTFail("daemon did not become ready") }
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Byte-counting accumulator: the echo of a 1-byte write is observed as ANY output growth
    /// (kernel tty echo precedes cat's own line-buffered copy, so the first growth is the echo).
    private final class ByteCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testEchoRoundTripLatency() throws {
        let client = DaemonClient()
        let surfaceID = UUID().uuidString
        // `/bin/cat` keeps the PTY quiet between probes (no prompt redraws to mistake for the
        // echo) while the default line discipline echoes each written byte immediately.
        guard case .ok = try client.request(.ensureSurface(
            surfaceID: surfaceID, cwd: nil, shell: "/bin/cat",
            rows: 24, cols: 80, scrollbackBytes: nil
        )) else { return XCTFail("ensureSurface failed") }

        let received = ByteCounter()
        let subscription = try client.subscribeSurfaceOutput(
            surfaceID: surfaceID, label: "echo-rtt"
        ) { data, _ in
            received.add(data.count)
        }
        defer { subscription.cancel() }
        // Let the spawn settle (cat prints nothing; any startup bytes land before the probes).
        Thread.sleep(forTimeInterval: 0.3)

        let warmup = 10
        let probes = 100
        var samples: [UInt64] = []
        samples.reserveCapacity(probes)
        for i in 0 ..< (warmup + probes) {
            let before = received.value
            let start = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(subscription.sendInput(Data([UInt8(ascii: "x")]), surfaceID: surfaceID),
                          "input frame failed at probe \(i)")
            let arrived = waitUntil(timeout: 2, pollIntervalMicros: 200) { received.value > before }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- start
            XCTAssertTrue(arrived, "echo never arrived at probe \(i)")
            if i >= warmup { samples.append(elapsed) }
        }

        let sorted = samples.sorted()
        func pct(_ q: Double) -> UInt64 {
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] / 1000
        }
        // Same shape as the other benches: one JSON line per metric for the scoreboard.
        print(#"{"benchmark":"echo_rtt_daemon","p50_us":\#(pct(0.5)),"p95_us":\#(pct(0.95)),"p99_us":\#(pct(0.99)),"max_us":\#((sorted.last ?? 0) / 1000),"probes":\#(samples.count)}"#)
        // Sanity ceiling, not a perf gate: an in-process socket + PTY echo beyond 50ms means
        // something is broken (the poll interval alone contributes ≤0.2ms).
        XCTAssertLessThan(pct(0.5), 50_000, "median echo RTT implausibly slow")
    }
}
#endif
