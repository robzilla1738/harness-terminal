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
/// Subsystem `com.robert.harness`, category `frame`. Enable with `PREVIEW_SIGNPOSTS=1 make preview`
/// (which launches `open … --args -HARNESS_FRAME_SIGNPOSTS 1`), by setting
/// `HARNESS_FRAME_SIGNPOSTS=1` in the app's launch environment (direct binary launch /
/// `xctrace record --template 'os_signpost' --launch …`), then read with
/// `log stream --predicate 'subsystem == "com.robert.harness"'`.
final class FrameSignposter: @unchecked Sendable {
    static let shared = FrameSignposter()

    let enabled: Bool

    #if canImport(os)
    private let signposter: OSSignposter
    private let logger: Logger
    #endif
    /// Recent `present` interval durations (ns) with their breakdown components, main-thread only
    /// (`recordPresent` is called from the surface's `presentFrame`). Flushed to the log as
    /// p50/p95/max every `presentLogEvery` frames. NOTE: the singleton blends samples from ALL
    /// presenting surfaces (splits/tabs) into one bucket — the percentiles are only attributable
    /// to a specific pipeline with a single visible surface (benchmarks read per-view
    /// `TerminalRenderStats` directly and are unaffected). The breakdown attributes a slow present:
    /// `drawableWait` = `nextDrawable()` (pool exhaustion / vsync pacing), `semaphoreWait` = the
    /// renderer's in-flight gate (GPU behind), `schedule` = `waitUntilScheduled()` (the bounded
    /// transaction-synchronized wait of the glitchless-resize path; 0 for async presents).
    private var presentSamples: [UInt64] = []
    private var drawableWaitSamples: [UInt64] = []
    private var semaphoreWaitSamples: [UInt64] = []
    private var scheduleSamples: [UInt64] = []
    /// Per-boundary encode split (from `TerminalRenderStats`): `instanceBuild` = CPU row encode +
    /// flatten (`buildFrameInstances`), `upload` = the GPU ring-slot memcpy / stable bind
    /// (`bindableInstanceBuffers`). Attributes a slow encode to the value boundary that paid it.
    private var instanceBuildSamples: [UInt64] = []
    private var uploadSamples: [UInt64] = []
    /// Presents skipped since the last flush — work was pending but nothing reached the glass that
    /// turn; the scheduler retried on a later tick. Counted per cause so a flush line can tell
    /// drawable-pool exhaustion (vsync/window-server pressure) from a renderer encode failure.
    private var droppedNilDrawable = 0
    private var droppedEncodeFailure = 0
    private let presentLogEvery = 120
    /// End-to-end echo latency: keyDown → the next present's completion (the CPU-side proxy for
    /// photon; scanout is at most one refresh later). One sample per keystroke — the pending
    /// timestamp is consumed by the first present after it; a present arriving more than
    /// `echoAttributionWindowNanos` later is unrelated (no echo came back — e.g. a blink tick or
    /// a dead key) and drops the pending sample instead of mis-attributing it. Main-thread only,
    /// like the present samples, and blended across surfaces the same way — attribute with a
    /// single visible surface. This is the number the SCORECARD's "input-to-photon" row was
    /// missing: `present` measures the pipeline's tail, this measures from the keystroke.
    private var pendingKeystrokeNanos: UInt64?
    private var echoSamples: [UInt64] = []
    private let echoAttributionWindowNanos: UInt64 = 500_000_000
    private let echoLogEvery = 60

    /// Why a present was skipped: `nilDrawable` = `nextDrawable()` returned nothing (pool
    /// exhausted / layer hidden), `encodeFailure` = the renderer bailed after acquiring one.
    enum FrameDropCause {
        case nilDrawable, encodeFailure
    }

    /// `enabled: nil` (production singleton) reads the environment; tests pass it explicitly.
    init(enabled: Bool? = nil) {
        // `open` (Finder, `make preview`) does not forward the calling shell's environment to a
        // GUI app, so the env var alone is unreachable in practice. Also accept the argument
        // domain — `open -n Harness.app --args -HARNESS_FRAME_SIGNPOSTS 1` lands in
        // `UserDefaults.standard` via NSArgumentDomain. One read at init; the hot path still
        // branches on the stored `enabled`.
        self.enabled = enabled
            ?? (ProcessInfo.processInfo.environment["HARNESS_FRAME_SIGNPOSTS"] == "1"
                || UserDefaults.standard.bool(forKey: "HARNESS_FRAME_SIGNPOSTS"))
        #if canImport(os)
        signposter = OSSignposter(subsystem: "com.robert.harness", category: "frame")
        logger = Logger(subsystem: "com.robert.harness", category: "frame")
        #endif
    }

    /// Record a `present` duration (ns) plus its breakdown and, every `presentLogEvery` frames,
    /// log p50/p95/max per component to the unified log — so the drawable/vsync stall is readable
    /// with `log stream --predicate 'subsystem == "com.robert.harness"'` (no Instruments needed).
    /// Main-thread only; a no-op when disabled (so the hot path stays a single branch).
    /// A keystroke headed for the PTY just left the input encoder. Arms the echo-latency sample
    /// the next present consumes. Main-thread only; a single branch when disabled.
    func noteKeystroke(at nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard enabled else { return }
        pendingKeystrokeNanos = nanos
    }

    /// Test seam: the echo samples accumulated since the last flush (µs percentiles math is
    /// covered separately; this pins arm/consume/window semantics).
    var testingEchoSampleCount: Int { echoSamples.count }
    var testingHasPendingKeystroke: Bool { pendingKeystrokeNanos != nil }

    func recordPresent(
        nanos: UInt64, drawableWait: UInt64 = 0, semaphoreWait: UInt64 = 0, schedule: UInt64 = 0,
        instanceBuild: UInt64 = 0, upload: UInt64 = 0,
        at now: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        guard enabled else { return }
        // Echo sample: this present is the first since the armed keystroke — charge it.
        if let pending = pendingKeystrokeNanos {
            pendingKeystrokeNanos = nil
            let elapsed = now &- pending
            if elapsed <= echoAttributionWindowNanos {
                echoSamples.append(elapsed)
                if echoSamples.count >= echoLogEvery {
                    let echo = Self.percentilesMicros(echoSamples)
                    let count = echoSamples.count
                    echoSamples.removeAll(keepingCapacity: true)
                    #if canImport(os)
                    logger.log("""
                    echo µs p50=\(echo.p50) p95=\(echo.p95) p99=\(echo.p99) max=\(echo.max) \
                    over \(count) keystrokes
                    """)
                    #endif
                }
            }
        }
        presentSamples.append(nanos)
        drawableWaitSamples.append(drawableWait)
        semaphoreWaitSamples.append(semaphoreWait)
        scheduleSamples.append(schedule)
        instanceBuildSamples.append(instanceBuild)
        uploadSamples.append(upload)
        guard presentSamples.count >= presentLogEvery else { return }
        let frames = presentSamples.count
        let total = Self.percentilesMicros(presentSamples)
        let drawable = Self.percentilesMicros(drawableWaitSamples)
        let semaphore = Self.percentilesMicros(semaphoreWaitSamples)
        let sched = Self.percentilesMicros(scheduleSamples)
        let build = Self.percentilesMicros(instanceBuildSamples)
        let up = Self.percentilesMicros(uploadSamples)
        let droppedDrawable = droppedNilDrawable
        let droppedEncode = droppedEncodeFailure
        presentSamples.removeAll(keepingCapacity: true)
        drawableWaitSamples.removeAll(keepingCapacity: true)
        semaphoreWaitSamples.removeAll(keepingCapacity: true)
        scheduleSamples.removeAll(keepingCapacity: true)
        instanceBuildSamples.removeAll(keepingCapacity: true)
        uploadSamples.removeAll(keepingCapacity: true)
        droppedNilDrawable = 0
        droppedEncodeFailure = 0
        #if canImport(os)
        logger.log("""
        present µs p50=\(total.p50) p95=\(total.p95) p99=\(total.p99) max=\(total.max) | \
        drawableWait p50=\(drawable.p50) p95=\(drawable.p95) p99=\(drawable.p99) | \
        semaphoreWait p50=\(semaphore.p50) p95=\(semaphore.p95) | \
        schedule p50=\(sched.p50) p95=\(sched.p95) | \
        instanceBuild p50=\(build.p50) p95=\(build.p95) | \
        upload p50=\(up.p50) p95=\(up.p95) | \
        dropped=\(droppedDrawable + droppedEncode) (drawable=\(droppedDrawable) encode=\(droppedEncode)) \
        over \(frames) frames
        """)
        #endif
    }

    /// Count a skipped present by cause; included in the periodic `recordPresent` flush line.
    /// Main-thread only; no-op when disabled.
    func recordFrameDrop(_ cause: FrameDropCause) {
        guard enabled else { return }
        switch cause {
        case .nilDrawable: droppedNilDrawable += 1
        case .encodeFailure: droppedEncodeFailure += 1
        }
    }

    // Internal (not private) so the unit tests pin the percentile math directly.
    static func percentilesMicros(_ samples: [UInt64]) -> (p50: UInt64, p95: UInt64, p99: UInt64, max: UInt64) {
        guard !samples.isEmpty else { return (0, 0, 0, 0) }
        let sorted = samples.sorted()
        return (
            sorted[sorted.count / 2] / 1000,
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] / 1000,
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))] / 1000,
            (sorted.last ?? 0) / 1000
        )
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
