import Darwin
import Dispatch
import Foundation
import XCTest
@testable import HarnessCore
@testable import HarnessDaemonCore

/// Measure-first for issue #27, Tier 0a: is the daemon's PTY master-drain rate gated by
/// "one `read()` per `DispatchSourceRead` wakeup" (today's `RealPty.startReading`), and would a
/// bounded read-ahead loop on a non-blocking master raise the ceiling?
///
/// This forks a real PTY whose child floods zeros to stdout and drains the master two ways:
///   - `readAhead == false`: exactly one `read(buf)` per `DispatchSourceRead` event — RealPty today.
///   - `readAhead == true`:  `O_NONBLOCK` master, loop `read()` until `EAGAIN` (capped) per event.
/// It is pure measurement — it changes no production code. The result decides whether Tier 2 (the
/// risky non-blocking-master rework) is worth doing. Gated by both `HARNESS_BENCHMARKS=1` and
/// `HARNESS_LIVE_DAEMON_TESTS=1` (it forks a child), so the normal suites never run it.
final class PtyDrainCeilingBenchmark: XCTestCase {
    private func skipUnlessEnabled() throws {
        _ = testSIGPIPEIgnored
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            env["HARNESS_BENCHMARKS"] == "1" && env["HARNESS_LIVE_DAEMON_TESTS"] == "1",
            "Set HARNESS_BENCHMARKS=1 and HARNESS_LIVE_DAEMON_TESTS=1 to run the PTY drain ceiling benchmark."
        )
    }

    /// All mutable drain state lives here so the `DispatchSource` handler (serialized on one queue)
    /// can mutate it without Swift 6 concurrent-capture errors. Access is single-queue + a final
    /// semaphore barrier, hence `@unchecked Sendable`.
    private final class DrainState: @unchecked Sendable {
        var total = 0
        var startNanos: UInt64 = 0
        var finished = false
        var wakeups = 0
        var maxBytesInOneWakeup = 0
    }

    private struct DrainResult {
        var bytes: Int
        var nanos: UInt64
        var wakeups: Int
        var maxBytesInOneWakeup: Int
        var mbps: Double { nanos == 0 ? 0 : (Double(bytes) / 1_000_000) / (Double(nanos) / 1_000_000_000) }
        var bytesPerWakeup: Int { wakeups == 0 ? 0 : bytes / wakeups }
    }

    private func drain(totalMiB: Int, bufSize: Int, readAhead: Bool, maxReadsPerWakeup: Int, rawTermios: Bool) -> DrainResult {
        let blocks = totalMiB * 1024 * 1024 / 65536
        var ws = winsize(ws_row: 48, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        var amaster: Int32 = -1
        // `rawTermios == false` passes nil termios → forkpty inherits the default line discipline,
        // exactly like production `RealPty.forkpty(&amaster, nil, nil, &winsize)`.
        let pid: pid_t
        if rawTermios {
            var raw = termios()
            cfmakeraw(&raw)
            pid = forkpty(&amaster, nil, &raw, &ws)
        } else {
            pid = forkpty(&amaster, nil, nil, &ws)
        }
        if pid < 0 { return DrainResult(bytes: 0, nanos: 0, wakeups: 0, maxBytesInOneWakeup: 0) }
        if pid == 0 {
            // Child: flood `blocks` × 64 KiB of zeros to stdout (the PTY slave), then exit.
            let args: [String] = ["/bin/dd", "if=/dev/zero", "bs=65536", "count=\(blocks)"]
            let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] = [nil]
            _ = execve("/bin/dd", argv, envp)
            _exit(127)
        }

        if readAhead {
            let flags = fcntl(amaster, F_GETFL, 0)
            _ = fcntl(amaster, F_SETFL, flags | O_NONBLOCK)
        }

        let queue = DispatchQueue(label: "pty-drain-bench")
        let source = DispatchSource.makeReadSource(fileDescriptor: amaster, queue: queue)
        let state = DrainState()
        let done = DispatchSemaphore(value: 0)
        var buffer = [UInt8](repeating: 0, count: bufSize)

        source.setEventHandler {
            if state.finished { return }
            state.wakeups += 1
            var thisWakeup = 0

            func readOnce() -> Int {
                buffer.withUnsafeMutableBytes { Darwin.read(amaster, $0.baseAddress, $0.count) }
            }
            func account(_ n: Int) {
                if state.startNanos == 0 { state.startNanos = DispatchTime.now().uptimeNanoseconds }
                state.total += n
                thisWakeup += n
            }

            if readAhead {
                var reads = 0
                loop: while reads < maxReadsPerWakeup {
                    let n = readOnce()
                    if n > 0 { account(n); reads += 1 }
                    else if n == 0 { state.finished = true; break }
                    else {
                        switch errno {
                        case EAGAIN, EWOULDBLOCK: break loop
                        case EINTR: continue
                        default: state.finished = true; break loop
                        }
                    }
                }
            } else {
                let n = readOnce()
                if n > 0 { account(n) }
                else if n == 0 { state.finished = true }
                else if !(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { state.finished = true }
            }

            if thisWakeup > state.maxBytesInOneWakeup { state.maxBytesInOneWakeup = thisWakeup }
            if state.finished { source.cancel() }
        }
        source.setCancelHandler {
            Darwin.close(amaster)
            done.signal()
        }
        source.resume()
        done.wait()
        let endNanos = DispatchTime.now().uptimeNanoseconds
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        return DrainResult(
            bytes: state.total,
            nanos: state.startNanos == 0 ? 0 : endNanos &- state.startNanos,
            wakeups: state.wakeups,
            maxBytesInOneWakeup: state.maxBytesInOneWakeup
        )
    }

    private func emit(_ name: String, _ r: DrainResult) {
        print("{\"benchmark\":\"\(name)\",\"bytes\":\(r.bytes),\"nanos\":\(r.nanos)," +
              "\"mbps\":\(String(format: "%.3f", r.mbps)),\"wakeups\":\(r.wakeups)," +
              "\"bytesPerWakeup\":\(r.bytesPerWakeup),\"maxBytesInOneWakeup\":\(r.maxBytesInOneWakeup)}")
    }

    /// Single-read-per-wakeup (RealPty today) vs bounded read-ahead, across read-buffer sizes.
    /// Run ≥3× and compare medians (forked-child rates are noisy). The decision: if read-ahead's
    /// `mbps` is materially higher and its `wakeups` materially lower, Tier 2 is justified; if not,
    /// the ceiling is elsewhere and Tier 2 should be dropped.
    func testPtyDrainCeilingSingleVsReadAhead() throws {
        try skipUnlessEnabled()
        let totalMiB = 64
        let bufSize = 64 * 1024
        for raw in [false, true] {
            let tag = raw ? "raw" : "default"
            let single = drain(totalMiB: totalMiB, bufSize: bufSize, readAhead: false, maxReadsPerWakeup: 1, rawTermios: raw)
            emit("pty_drain_single_\(tag)", single)
            let ahead = drain(totalMiB: totalMiB, bufSize: bufSize, readAhead: true, maxReadsPerWakeup: 16, rawTermios: raw)
            emit("pty_drain_readahead16_\(tag)", ahead)
        }
    }

    /// End-to-end through the *real* production `RealPty`: PTY read → `Data` copy → scrollback lock
    /// → `deliveryQueue` hop → subscriber. A `/bin/sh` child floods `mib` MiB of zeros. The gap
    /// between this and `pty_drain_single_default` above is the daemon's per-~1 KB-chunk downstream
    /// overhead (the thing Tier 3 could reduce); if there's no gap, there's nothing to optimize.
    private final class Counter: @unchecked Sendable {
        var bytes = 0
        var callbacks = 0
        var startNanos: UInt64 = 0
        var doneNanos: UInt64 = 0
        let target: Int
        let done = DispatchSemaphore(value: 0)
        init(target: Int) { self.target = target }
    }

    func testRealPtyEndToEndDrain() throws {
        try skipUnlessEnabled()
        let mib = 48
        let target = mib * 1024 * 1024
        let pty = try RealPty(
            id: UUID().uuidString,
            cwd: NSTemporaryDirectory(),
            shell: "/bin/sh",
            rows: 48,
            cols: 160,
            scrollbackBytes: 2 * 1024 * 1024
        )
        defer { pty.close() }

        let counter = Counter(target: target)
        _ = pty.subscribe { data, _ in
            if counter.startNanos == 0 { counter.startNanos = DispatchTime.now().uptimeNanoseconds }
            counter.bytes += data.count
            counter.callbacks += 1
            if counter.bytes >= counter.target, counter.doneNanos == 0 {
                counter.doneNanos = DispatchTime.now().uptimeNanoseconds
                counter.done.signal()
            }
        }

        let blocks = target / 65536
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            pty.write("dd if=/dev/zero bs=65536 count=\(blocks) 2>/dev/null\n")
        }
        _ = counter.done.wait(timeout: .now() + 30)

        let nanos = (counter.startNanos == 0 || counter.doneNanos == 0) ? 0 : counter.doneNanos &- counter.startNanos
        let mbps = nanos == 0 ? 0 : (Double(counter.bytes) / 1_000_000) / (Double(nanos) / 1_000_000_000)
        let avgChunk = counter.callbacks == 0 ? 0 : counter.bytes / counter.callbacks
        print("{\"benchmark\":\"real_pty_end_to_end_drain\",\"bytes\":\(counter.bytes),\"nanos\":\(nanos)," +
              "\"mbps\":\(String(format: "%.3f", mbps)),\"callbacks\":\(counter.callbacks),\"avgChunkBytes\":\(avgChunk)}")
        XCTAssertGreaterThan(counter.bytes, target / 2, "should have drained most of the flood")
    }
}
