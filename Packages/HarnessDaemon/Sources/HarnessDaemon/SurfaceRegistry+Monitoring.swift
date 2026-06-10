import Foundation
import HarnessCore

/// Output monitoring (activity / silence / bell) — the per-surface flag drain, the OSC-aware
/// bell scanner, and the 500 ms tick with its idle precheck. Mechanically extracted from
/// `SurfaceRegistry.swift` (PR-31): same members, same locks, zero logic change. The stored
/// state (`monitors`/`monitorLock`/`monitorTimer`/`silenceArmed`/`monitorFullPasses`) stays
/// on the class — Swift extensions cannot host stored properties — and the single-lock
/// serialization (`lock` for the registry, `monitorLock` for the flags) is a documented
/// correctness invariant this split deliberately does not redesign.
extension SurfaceRegistry {
    // MARK: Monitoring (Phase 5)
    /// Cheap per-surface output state, updated on the PTY read thread and drained by
    /// `processMonitors` on a timer. Kept off `lock` (its own tiny lock) so the hot output
    /// path never contends with layout mutations.
    struct SurfaceMonitor {
        var sawOutput = false
        var sawBell = false
        var lastOutput = Date()
        /// OSC-aware bell-scan state, carried across PTY chunks (a sequence can split over reads).
        var bellScan: SurfaceRegistry.BellScanState = .normal
    }

    /// State for the lightweight bell scan in `noteSurfaceOutput`. A BEL (0x07) is a real terminal
    /// bell only in `normal`; a BEL terminating or inside a string sequence (OSC/DCS/APC/PM/SOS) is
    /// not — most importantly the OSC 133 prompt marks shell integration emits on every prompt.
    enum BellScanState: Equatable { case normal, esc, string, stringEsc }

    /// Scan `data` for real control-BELs, threading `state` across calls so a sequence split across
    /// chunks is handled. Returns true if a genuine bell (not a string-sequence terminator) was
    /// seen. Static + pure so it is unit-testable.
    static func scanForBell(_ data: Data, state: inout BellScanState) -> Bool {
        var sawBell = false
        for byte in data {
            switch state {
            case .normal:
                if byte == 0x1B { state = .esc }
                else if byte == 0x07 { sawBell = true }
            case .esc:
                switch byte {
                case 0x5D, 0x50, 0x5F, 0x5E, 0x58: state = .string   // OSC ] / DCS P / APC _ / PM ^ / SOS X
                case 0x1B: state = .esc                              // ESC restarts escape parsing
                case 0x07: sawBell = true; state = .normal           // BEL after a non-string ESC: real
                default: state = .normal                             // CSI, ST, other escapes
                }
            case .string:
                // A BEL terminates an OSC (xterm) and is data inside the others — never a bell.
                // CAN/SUB abort a string sequence (as the VT parser does), so an unterminated string
                // can't pin the scanner and swallow every later bell.
                if byte == 0x07 { state = .normal }
                else if byte == 0x18 || byte == 0x1A { state = .normal } // CAN / SUB abort
                else if byte == 0x1B { state = .stringEsc }
            case .stringEsc:
                if byte == 0x5C { state = .normal }                  // ST (ESC \) terminates the string
                else if byte == 0x1B { state = .stringEsc }          // another ESC; keep waiting
                else { state = .string }                             // ESC was data; stay in the string
            }
        }
        return sawBell
    }

    final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func update(_ flag: Bool) { lock.lock(); value = flag; lock.unlock() }
        func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    var monitorFullPassCountForTesting: Int {
        monitorLock.lock(); defer { monitorLock.unlock() }; return monitorFullPasses
    }

    /// Mirror `monitor-silence > 0` into `silenceArmed` — the exact read `processMonitors`
    /// performs (global resolve). Called at startup and whenever `setOption` touches the key.
    func refreshSilenceArmedCache() {
        silenceArmed.update((optionStore.get("monitor-silence")?.intValue ?? 0) > 0)
    }

    func processMonitorsForTesting() { processMonitors() }

    func noteSurfaceOutputForTesting(surfaceKey: String, data: Data) {
        noteSurfaceOutput(surfaceKey: surfaceKey, data: data)
    }

    var monitorEntryKeysForTesting: [String] {
        monitorLock.lock(); defer { monitorLock.unlock() }; return Array(monitors.keys)
    }

    func startMonitorTimer() {
        let timer = DispatchSource.makeTimerSource(queue: hookQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.processMonitors() }
        timer.resume()
        monitorTimer = timer
    }

    /// Stop the periodic activity/silence/bell monitor timer (orderly daemon shutdown / tests).
    public func stopMonitoring() {
        monitorTimer?.cancel()
        monitorTimer = nil
    }

    /// Record output for a surface — runs on the PTY read thread, so it must stay cheap
    /// (no `lock`, no snapshot walk): just flag output / bell and stamp the time.
    func noteSurfaceOutput(surfaceKey: String, data: Data) {
        monitorLock.lock()
        var m = monitors[surfaceKey] ?? SurfaceMonitor()
        m.sawOutput = true
        m.lastOutput = Date()
        // Parser-aware bell: a raw `data.contains(0x07)` mistakes the OSC-terminator BEL that shell
        // integration emits on every prompt (OSC 133) for a real terminal bell. The scan threads
        // its state through `m.bellScan` so a sequence spanning chunks is still handled correctly.
        if Self.scanForBell(data, state: &m.bellScan) { m.sawBell = true }
        monitors[surfaceKey] = m
        monitorLock.unlock()
    }

    /// Drain the monitor state (timer) and raise activity/silence/bell alerts on non-current
    /// windows, gated on the matching option. Sets the tab flag (surfaced as `#`/`~`/`!` in
    /// `#{window_flags}`) and fires the hook — both only on a real transition.
    private func processMonitors() {
        monitorLock.lock()
        // Idle precheck (monitorLock only): with no fresh output/bell this tick and silence
        // monitoring disarmed, there is nothing to evaluate — skip the drain, the registry
        // lock and the option reads (this timer fires twice a second forever; monitor
        // entries persist per-surface after any output, so `drained.isEmpty` alone never
        // gates a session that has ever produced output). Correctness is preserved:
        // activity/bell alerts need a fresh flag by definition; silence needs per-tick idle
        // evaluation only while armed (cached via `silenceArmed`); and the orphan sweep
        // below still runs in time, because an entry recreated by a racing PTY read is born
        // with `sawOutput = true` (orderly closes evict their entries eagerly).
        let hasFreshFlags = monitors.contains { $0.value.sawOutput || $0.value.sawBell }
        if !hasFreshFlags, !silenceArmed.read() {
            monitorLock.unlock()
            return
        }
        monitorFullPasses += 1
        let now = Date()
        var drained: [String: (sawOutput: Bool, sawBell: Bool, idle: TimeInterval)] = [:]
        for (key, m) in monitors {
            drained[key] = (m.sawOutput, m.sawBell, now.timeIntervalSince(m.lastOutput))
            monitors[key]?.sawOutput = false
            monitors[key]?.sawBell = false
        }
        monitorLock.unlock()
        guard !drained.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        let wantActivity = optionStore.get("monitor-activity")?.boolValue ?? false
        let wantBell = optionStore.get("monitor-bell")?.boolValue ?? true
        let silenceSeconds = optionStore.get("monitor-silence")?.intValue ?? 0
        // The orphan sweep runs even when every monitor option is off, so dead-surface keys never
        // accumulate; only the alert processing below is gated on the options being enabled.
        let monitoring = wantActivity || wantBell || silenceSeconds > 0
        var changed = false
        var fired: [(HookEvent, String)] = []
        var orphans: [String] = []
        for (key, st) in drained {
            guard let match = editor.tab(forSurfaceKey: key) else {
                // Output for a surface with no tab — an in-flight PTY read raced `closeSurfaces`
                // and re-created the monitor entry after teardown. Evict it so `monitors` can't
                // grow unbounded with dead-surface keys that nothing will ever clean.
                orphans.append(key)
                continue
            }
            guard monitoring,
                  !editor.tabIsCurrent(workspaceID: match.workspaceID, tabID: match.tabID) else { continue }
            if wantActivity, st.sawOutput,
               editor.setTabAlerts(workspaceID: match.workspaceID, tabID: match.tabID, activity: true) {
                changed = true; fired.append((.paneActivity, key))
            }
            if wantBell, st.sawBell,
               editor.setTabAlerts(workspaceID: match.workspaceID, tabID: match.tabID, bell: true) {
                changed = true; fired.append((.paneBell, key))
            }
            if silenceSeconds > 0, !st.sawOutput, st.idle >= Double(silenceSeconds),
               editor.setTabAlerts(workspaceID: match.workspaceID, tabID: match.tabID, silence: true) {
                changed = true; fired.append((.paneSilence, key))
            }
        }
        if changed { commit() }
        for (event, key) in fired { fireHookLocked(event, surfaceKey: key) }
        if !orphans.isEmpty {
            monitorLock.lock()
            for key in orphans { monitors.removeValue(forKey: key) }
            monitorLock.unlock()
        }
    }
}
