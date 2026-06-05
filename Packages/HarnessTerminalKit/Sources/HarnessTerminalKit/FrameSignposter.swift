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
    /// Presents skipped since the last flush (nil drawable / encode failure) — work was pending
    /// but nothing reached the glass that turn; the scheduler retried on a later tick.
    private var droppedFrames = 0
    private let presentLogEvery = 120

    init() {
        // `open` (Finder, `make preview`) does not forward the calling shell's environment to a
        // GUI app, so the env var alone is unreachable in practice. Also accept the argument
        // domain — `open -n Harness.app --args -HARNESS_FRAME_SIGNPOSTS 1` lands in
        // `UserDefaults.standard` via NSArgumentDomain. One read at init; the hot path still
        // branches on the stored `enabled`.
        enabled = ProcessInfo.processInfo.environment["HARNESS_FRAME_SIGNPOSTS"] == "1"
            || UserDefaults.standard.bool(forKey: "HARNESS_FRAME_SIGNPOSTS")
        #if canImport(os)
        signposter = OSSignposter(subsystem: "com.robert.harness", category: "frame")
        logger = Logger(subsystem: "com.robert.harness", category: "frame")
        #endif
    }

    /// Record a `present` duration (ns) plus its breakdown and, every `presentLogEvery` frames,
    /// log p50/p95/max per component to the unified log — so the drawable/vsync stall is readable
    /// with `log stream --predicate 'subsystem == "com.robert.harness"'` (no Instruments needed).
    /// Main-thread only; a no-op when disabled (so the hot path stays a single branch).
    func recordPresent(
        nanos: UInt64, drawableWait: UInt64 = 0, semaphoreWait: UInt64 = 0, schedule: UInt64 = 0,
        instanceBuild: UInt64 = 0, upload: UInt64 = 0
    ) {
        guard enabled else { return }
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
        let dropped = droppedFrames
        presentSamples.removeAll(keepingCapacity: true)
        drawableWaitSamples.removeAll(keepingCapacity: true)
        semaphoreWaitSamples.removeAll(keepingCapacity: true)
        scheduleSamples.removeAll(keepingCapacity: true)
        instanceBuildSamples.removeAll(keepingCapacity: true)
        uploadSamples.removeAll(keepingCapacity: true)
        droppedFrames = 0
        #if canImport(os)
        logger.log("""
        present µs p50=\(total.p50) p95=\(total.p95) max=\(total.max) | \
        drawableWait p50=\(drawable.p50) p95=\(drawable.p95) | \
        semaphoreWait p50=\(semaphore.p50) p95=\(semaphore.p95) | \
        schedule p50=\(sched.p50) p95=\(sched.p95) | \
        instanceBuild p50=\(build.p50) p95=\(build.p95) | \
        upload p50=\(up.p50) p95=\(up.p95) | \
        dropped=\(dropped) over \(frames) frames
        """)
        #endif
    }

    /// Count a skipped present (nil drawable / encode failure); included in the periodic
    /// `recordPresent` flush line. Main-thread only; no-op when disabled.
    func recordFrameDrop() {
        guard enabled else { return }
        droppedFrames += 1
    }

    // Internal (not private) so the unit tests pin the percentile math directly.
    static func percentilesMicros(_ samples: [UInt64]) -> (p50: UInt64, p95: UInt64, max: UInt64) {
        guard !samples.isEmpty else { return (0, 0, 0) }
        let sorted = samples.sorted()
        return (
            sorted[sorted.count / 2] / 1000,
            sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] / 1000,
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
