import AppKit
import Darwin
import Foundation
import HarnessCore

/// Live mapping of surface UUID → shell PID + current working directory.
///
/// Why this exists: the renderer only fires `terminalDidChangeWorkingDirectory`
/// when the shell emits OSC 7. Many shells (notably fish without explicit
/// integration) never do this, leaving the sidebar stuck on the launch cwd.
///
/// Industry-standard fix (used by iTerm2, Alacritty's hooks, Warp): poll the
/// shell process's actual cwd via `proc_pidinfo(PROC_PIDVNODEPATHINFO)` every
/// 500ms. We discover each surface's shell PID by scanning the Harness app's
/// descendants and reading their `HARNESS_SURFACE` env var via `sysctl`.
@MainActor
final class SurfaceShellTracker {
    static let shared = SurfaceShellTracker()

    private var timer: DispatchSourceTimer?
    private var lastReportedCwd: [String: String] = [:]
    /// Set while a background scan is in flight so ticks don't pile up — a proc-tree walk on a
    /// loaded machine can exceed the 500ms interval, and stacking scans just wastes CPU.
    private var scanning = false
    /// `true` between `start()` and `stop()` — distinct from `timer != nil` because the timer
    /// is also parked while the app is inactive (idle efficiency), and an activate must not
    /// resurrect a tracker that was never started (headless tests) or was stopped.
    private var started = false
    /// Consecutive scans with zero cwd changes. Past `idleScansBeforeBackoff` the cadence
    /// stretches to `relaxedInterval`; any change — or a `bumpScan` from surface create/focus —
    /// snaps it back to `baseInterval`.
    private var unchangedScans = 0
    private var currentInterval: TimeInterval = SurfaceShellTracker.baseInterval
    private static let baseInterval: TimeInterval = 0.5
    private static let relaxedInterval: TimeInterval = 2.0
    /// ~5 s of stability before relaxing — long enough that interactive bursts (cd, tab
    /// switching) never see the slow cadence, short enough to matter for idle power.
    private static let idleScansBeforeBackoff = 10
    /// Serial queue for the blocking `proc_listpids` / `sysctl(KERN_PROCARGS2)` / `proc_pidinfo`
    /// syscalls. Kept off the main thread: scanning every process on a busy machine can take
    /// many milliseconds, and doing it on `.main` every 500ms drops frames.
    private static let scanQueue = DispatchQueue(label: "com.robert.harness.shell-tracker")

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        // Park while inactive: an inactive app's tabs rarely change cwd, and a 2 Hz
        // process-tree walk is exactly the kind of background wakeup macOS punishes.
        // Changes made while away are caught by the activate-time bumpScan.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        scheduleTimer(interval: currentInterval)
    }

    func stop() {
        started = false
        NotificationCenter.default.removeObserver(self)
        cancelTimer()
    }

    /// Force a re-scan immediately (call after creating a new tab/surface so we don't wait
    /// for the next tick), and snap a relaxed cadence back to the base interval.
    func bumpScan() {
        resetCadence()
        tick()
    }

    /// Lighter than `bumpScan`: the user is interacting (pane/tab focus change), so a
    /// relaxed cadence snaps back to responsive — but no immediate scan is forced (focus
    /// alone doesn't move a cwd; the next tick at base cadence is soon enough).
    func noteUserInteraction() {
        resetCadence()
    }

    @objc private func appDidBecomeActive() {
        guard started, timer == nil else { return }
        resetCadence()
        scheduleTimer(interval: currentInterval)
        tick() // catch up immediately on anything that moved while parked
    }

    @objc private func appDidResignActive() {
        cancelTimer()
    }

    private func scheduleTimer(interval: TimeInterval) {
        cancelTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func resetCadence() {
        unchangedScans = 0
        guard currentInterval != Self.baseInterval else { return }
        currentInterval = Self.baseInterval
        if timer != nil { scheduleTimer(interval: currentInterval) }
    }

    /// Adaptive cadence bookkeeping, fed by `applyCwds` with whether the scan changed anything.
    private func noteScanResult(changedAnything: Bool) {
        if changedAnything {
            resetCadence()
            return
        }
        unchangedScans += 1
        if unchangedScans >= Self.idleScansBeforeBackoff, currentInterval != Self.relaxedInterval {
            currentInterval = Self.relaxedInterval
            if timer != nil { scheduleTimer(interval: currentInterval) }
        }
    }

    // MARK: Test seams (cadence + pause/resume are timing behavior — assert state, not clocks)

    var currentIntervalForTesting: TimeInterval { currentInterval }
    var timerIsScheduledForTesting: Bool { timer != nil }
    func noteScanResultForTesting(changedAnything: Bool) { noteScanResult(changedAnything: changedAnything) }

    private func tick() {
        // `scanning` is read and written here on the main actor (the class is @MainActor),
        // so the guard + assignment below are an atomic check-and-set from the actor's
        // perspective: no second tick() — from the timer *or* bumpScan() — can slip through
        // between the guard and the assignment. This is what makes the flag safe without
        // an additional lock: both tick() call sites run on the main actor before the async
        // dispatch hands work to scanQueue.
        guard !scanning else { return }
        scanning = true
        Self.scanQueue.async { [weak self] in
            let cwds = Self.computeSurfaceCwds() // all blocking syscalls happen here, off-main
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scanning = false
                    self.applyCwds(cwds)
                }
            }
        }
    }

    /// Apply a fresh surface→cwd scan on the main actor: forget dead surfaces and push every
    /// changed cwd to the coordinator. Pure dictionary work — no syscalls, so it's cheap.
    private func applyCwds(_ cwds: [String: String]) {
        var changedAnything = false
        let live = Set(cwds.keys)
        for surface in lastReportedCwd.keys where !live.contains(surface) {
            lastReportedCwd.removeValue(forKey: surface)
            changedAnything = true // a surface died; stay at the responsive cadence
        }
        let coordinator = SessionCoordinator.shared
        for (surfaceID, cwd) in cwds where lastReportedCwd[surfaceID] != cwd {
            changedAnything = true
            lastReportedCwd[surfaceID] = cwd
            guard let uuid = UUID(uuidString: surfaceID) else { continue }
            coordinator.surfaceShellTrackerDidUpdateCwd(uuid, cwd: cwd)
        }
        noteScanResult(changedAnything: changedAnything)
    }

    // MARK: - Process introspection (pure syscalls; run off the main actor)

    /// Walk the app's process subtree, map each `HARNESS_SURFACE` to the deepest readable shell
    /// PID, and read that PID's cwd. Returns surface-id → cwd for every live surface.
    ///
    /// `HARNESS_SURFACE` propagates through `/usr/bin/login` → `/usr/bin/env` → the user's shell,
    /// so multiple PIDs in the chain carry the same surface ID. We want the *deepest* one: the
    /// outer wrappers are typically setuid `login` processes whose cwds macOS won't expose to a
    /// user-owned reader.
    private nonisolated static func computeSurfaceCwds() -> [String: String] {
        let tree = processTree(rootedAt: getpid())
        var candidates: [String: [(pid: pid_t, depth: Int)]] = [:]
        for entry in tree {
            guard let env = environment(of: entry.pid),
                  let surface = env["HARNESS_SURFACE"], !surface.isEmpty
            else { continue }
            candidates[surface, default: []].append((entry.pid, entry.depth))
        }
        var result: [String: String] = [:]
        for (surface, list) in candidates {
            let sorted = list.sorted { $0.depth > $1.depth }
            // Deepest PID that yields a readable cwd (skip wrappers we can't introspect).
            if let cwd = sorted.lazy.compactMap({ cwd(for: $0.pid) }).first {
                result[surface] = cwd
            }
        }
        return result
    }


    /// Returns every descendant of `root` along with its depth in the tree
    /// (root would be depth 0, immediate children depth 1, …). Used so we can
    /// prefer deeper PIDs when picking which process represents a surface.
    private nonisolated static func processTree(rootedAt root: pid_t) -> [(pid: pid_t, depth: Int)] {
        // One source of process-tree truth: `ProcessScan.parentMap()` is the shared primitive the
        // daemon's agent scanner uses too (previously this view kept its own `proc_listpids` +
        // `parentPID` copy, which could drift). We still compute depth here since the tracker
        // prefers the deepest PID per surface.
        let parents = ProcessScan.parentMap()
        var result: [(pid: pid_t, depth: Int)] = []
        for candidate in parents.keys where candidate != root {
            var cursor = candidate
            var depth = 0
            while let parent = parents[cursor], parent != 0, depth < 32 {
                depth += 1
                if parent == root {
                    result.append((candidate, depth))
                    break
                }
                cursor = parent
            }
        }
        return result
    }

    /// Read another process's working directory via `proc_pidinfo`.
    nonisolated static func cwd(for pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let bytes = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard bytes == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                decodeBoundedCString($0, capacity: Int(MAXPATHLEN))
            }
        }
    }

    /// Read another process's argv + envp via `sysctl(KERN_PROCARGS2)`.
    /// Returns the env dictionary (or `nil` on failure / permission denial).
    nonisolated static func environment(of pid: pid_t) -> [String: String]? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBufferPointer({ ptr -> Int32 in
            sysctl(&mib, 3, ptr.baseAddress, &size, nil, 0)
        }) == 0 else { return nil }

        // KERN_PROCARGS2 layout:
        //   int argc
        //   exec_path\0
        //   argv[0]\0 argv[1]\0 ... argv[argc-1]\0
        //   envp[0]\0 envp[1]\0 ... \0
        guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
        let argc: Int32 = buffer.withUnsafeBytes { rawPtr in
            rawPtr.load(as: Int32.self)
        }
        var cursor = MemoryLayout<Int32>.size

        // Skip the exec path (NUL-terminated) and any padding NULs.
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }

        // Skip argc strings (the argv array).
        var skipped: Int32 = 0
        while skipped < argc, cursor < size {
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            cursor += 1
            skipped += 1
        }

        // Now we're at envp; each entry is "KEY=VALUE\0".
        var env: [String: String] = [:]
        while cursor < size {
            let start = cursor
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            if cursor == start { break }
            let slice = buffer[start..<cursor]
            if let entry = String(bytes: slice, encoding: .utf8),
               let eq = entry.firstIndex(of: "=")
            {
                let key = String(entry[..<eq])
                let value = String(entry[entry.index(after: eq)...])
                env[key] = value
            }
            cursor += 1
        }
        return env
    }
}
