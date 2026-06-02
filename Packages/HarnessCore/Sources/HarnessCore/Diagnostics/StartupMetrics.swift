import Foundation
#if canImport(os)
import os
#endif

/// Opt-in startup timing for diagnosing launch latency. **Off by default** — when
/// disabled every `mark` is a single branch, so the call sites are safe to leave on
/// the launch path. Enable with `HARNESS_STARTUP_METRICS=1`; the timeline is logged
/// live to the unified log (Console.app / `log stream`) under
/// `subsystem == "com.robert.harness", category == "startup"`.
///
/// Mirrors `DaemonMetrics`: a process-wide `shared` instance, env-gated, with
/// monotonic timestamps. Marks are **idempotent** (only the first occurrence of a
/// phase is recorded), so callers don't need their own "did I already mark this"
/// flags — the first window, first surface, first drawable, etc. record once.
public final class StartupMetrics: @unchecked Sendable {
    /// The launch milestones we time, in their expected order. `launchStart`
    /// anchors the timeline; every other phase is reported as a delta from it.
    public enum Phase: String, CaseIterable, Sendable {
        case launchStart
        case firstWindow
        case firstSurfaceAttached
        case firstDrawablePresented
        case daemonConnected
        case firstSnapshot
    }

    public static let shared = StartupMetrics()

    /// Whether timing is being recorded. Check before doing any work so the
    /// disabled case stays a single branch.
    public let enabled: Bool

    private let lock = NSLock()
    private var marks: [(phase: Phase, nanos: UInt64)] = []
    #if canImport(os)
    // Apple's unified log (Console.app / `log stream`). Linux has no equivalent; the file log
    // under `logs/startup.log` is the durable sink there.
    private let logger = Logger(subsystem: "com.robert.harness", category: "startup")
    #endif
    /// Whether to also append marks to `logs/startup.log`. True only for the
    /// env-constructed `shared` instance — test-constructed instances never touch
    /// the filesystem.
    private let fileLoggingEnabled: Bool

    /// `~/Library/Application Support/Harness/logs/startup.log` (or under `HARNESS_HOME`).
    public static var logURL: URL { HarnessPaths.logsDirectory.appendingPathComponent("startup.log") }

    /// Reads `HARNESS_STARTUP_METRICS` once. Tests pass `enabled:` explicitly for
    /// deterministic behavior (and never write to disk).
    public init(enabled: Bool? = nil) {
        if let enabled {
            self.enabled = enabled
            self.fileLoggingEnabled = false
        } else {
            let on = ProcessInfo.processInfo.environment["HARNESS_STARTUP_METRICS"] == "1"
            self.enabled = on
            self.fileLoggingEnabled = on
        }
    }

    /// Record the first time `phase` is reached and log it live as `<phase> +<Δms>`.
    /// Repeat marks of the same phase are ignored. `at` is injectable for tests;
    /// production uses the monotonic uptime clock.
    public func mark(_ phase: Phase, at nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        guard enabled else { return }
        // Hold the lock across both sinks so the unified-log and file lines never interleave
        // or reorder, even if two phases are marked from different threads. Marks are few
        // (one per phase) and infrequent, so lock-held I/O here is negligible.
        lock.lock()
        defer { lock.unlock() }
        guard !marks.contains(where: { $0.phase == phase }) else { return }
        let isFirst = marks.isEmpty
        marks.append((phase, nanos))
        let deltaMs = Double(nanos &- marks[0].nanos) / 1_000_000
        #if canImport(os)
        logger.log("\(phase.rawValue, privacy: .public) +\(deltaMs, format: .fixed(precision: 1))ms")
        #endif
        // Durable, capture-anywhere sink (mirrors the daemon's dual stderr+file log): the
        // unified log isn't always readable from headless/sandboxed contexts, but a file
        // under the logs dir always is. Best-effort; never affects launch on failure.
        if fileLoggingEnabled {
            appendToLog(String(format: "%@ +%.1fms\n", phase.rawValue, deltaMs), truncate: isFirst)
        }
    }

    /// Append one line to `logs/startup.log`; `truncate` starts a fresh file for this
    /// launch (the first mark). All failures are swallowed — diagnostics must never
    /// interfere with startup.
    private func appendToLog(_ line: String, truncate: Bool) {
        try? HarnessPaths.ensureDirectories()
        let url = Self.logURL
        let data = Data(line.utf8)
        if truncate {
            try? data.write(to: url)
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// Milliseconds from `launchStart` to `phase`, or nil if either isn't recorded.
    public func elapsedMs(_ phase: Phase) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let start = marks.first(where: { $0.phase == .launchStart })?.nanos,
              let target = marks.first(where: { $0.phase == phase })?.nanos else { return nil }
        return Double(target &- start) / 1_000_000
    }

    /// Phases recorded so far, in the order they occurred.
    public func recordedPhases() -> [Phase] {
        lock.lock()
        defer { lock.unlock() }
        return marks.map(\.phase)
    }

    /// A one-line timeline summary (`launchStart→firstWindow=2.1ms …`), or a
    /// disabled notice. Also logged on demand and used by tests.
    public func report() -> String {
        guard enabled else { return "startup metrics: disabled (set HARNESS_STARTUP_METRICS=1)" }
        lock.lock()
        let snapshot = marks
        lock.unlock()
        guard let base = snapshot.first?.nanos else { return "startup: no marks" }
        let parts = snapshot.map { mark -> String in
            let ms = Double(mark.nanos &- base) / 1_000_000
            return String(format: "%@=%.1fms", mark.phase.rawValue, ms)
        }
        return "startup: " + parts.joined(separator: " ")
    }
}
