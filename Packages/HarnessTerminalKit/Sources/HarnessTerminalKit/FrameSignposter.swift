import Foundation
#if canImport(os)
import os
#endif

/// Opt-in `os_signpost` instrumentation of the per-frame pipeline — parse → build → present — for
/// profiling input-to-photon latency on the `os_signpost` track in Instruments (Time Profiler /
/// Points of Interest). **Off by default**: when `HARNESS_FRAME_SIGNPOSTS != 1` every call is a
/// single branch, so the brackets are safe to leave on the hot path (mirrors `StartupMetrics`).
///
/// The `present` interval is the one to watch: it wraps the renderer's `present`, which does
/// `nextDrawable()` + `inFlightSemaphore.wait()` on the main thread — i.e. it *includes the
/// drawable/GPU back-pressure (vsync) stall*. `0b`'s benchmark already showed the CPU-side
/// parse+build is ~16µs, so if typing feels laggy the `present` interval is where the time is, and
/// that is what the vsync/drawable-pacing work targets.
///
/// Subsystem `com.robert.harness`, category `frame`. Profile a `make preview` run with
/// `HARNESS_FRAME_SIGNPOSTS=1` set in the app's environment, or `xctrace record --template
/// 'os_signpost'`.
final class FrameSignposter: @unchecked Sendable {
    static let shared = FrameSignposter()

    let enabled: Bool

    #if canImport(os)
    private let signposter: OSSignposter
    private let logger: Logger
    #endif
    /// Recent `present` interval durations (ns), main-thread only (`recordPresent` is called from
    /// `presentBuiltFrame`). Flushed to the log as p50/p95/max every `presentLogEvery` frames.
    private var presentSamples: [UInt64] = []
    private let presentLogEvery = 120

    init() {
        enabled = ProcessInfo.processInfo.environment["HARNESS_FRAME_SIGNPOSTS"] == "1"
        #if canImport(os)
        signposter = OSSignposter(subsystem: "com.robert.harness", category: "frame")
        logger = Logger(subsystem: "com.robert.harness", category: "frame")
        #endif
    }

    /// Record a `present` duration (ns) and, every `presentLogEvery` frames, log p50/p95/max to the
    /// unified log — so the drawable/vsync stall is readable with
    /// `log stream --predicate 'subsystem == "com.robert.harness"'` (no Instruments needed).
    /// Main-thread only; a no-op when disabled (so the hot path stays a single branch).
    func recordPresent(nanos: UInt64) {
        guard enabled else { return }
        presentSamples.append(nanos)
        guard presentSamples.count >= presentLogEvery else { return }
        let sorted = presentSamples.sorted()
        let p50 = sorted[sorted.count / 2] / 1000
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] / 1000
        let mx = (sorted.last ?? 0) / 1000
        presentSamples.removeAll(keepingCapacity: true)
        #if canImport(os)
        logger.log("present µs p50=\(p50) p95=\(p95) max=\(mx) over \(sorted.count) frames")
        #endif
    }

    #if canImport(os)
    /// Run `body` inside a named signpost interval (no-op overhead when disabled). Reentrancy- and
    /// concurrency-safe: each call carries its own interval state, so overlapping frames (off-main
    /// build while main presents) don't confuse the trace.
    @inline(__always)
    func interval<T>(_ name: StaticString, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return body()
    }

    /// Emit a zero-width event (e.g. the cross-thread main hop) to mark a point on the timeline.
    @inline(__always)
    func event(_ name: StaticString) {
        guard enabled else { return }
        signposter.emitEvent(name)
    }
    #else
    @inline(__always)
    func interval<T>(_ name: StaticString, _ body: () -> T) -> T { body() }

    @inline(__always)
    func event(_ name: StaticString) {}
    #endif
}
