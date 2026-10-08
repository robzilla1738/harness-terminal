import Foundation
import HarnessCore
import HarnessTerminalEngine

/// Output monitoring (activity / silence / bell) — the per-surface flag drain, the OSC-aware
/// bell scanner, and the 500 ms tick with its idle precheck. Mechanically extracted from
/// `SurfaceRegistry.swift` (PR-31): same members, same locks, zero logic change. The stored
/// state (`monitors`/`monitorLock`/`monitorTimer`/`silenceArmed`/`monitorFullPasses`) stays
/// on the class — Swift extensions cannot host stored properties — and the single-lock
/// serialization (`lock` for the registry, `monitorLock` for the flags) is a documented
/// correctness invariant this split deliberately does not redesign.
extension SurfaceRegistry {
    // MARK: Monitoring (Phase 5)
    /// Cheap per-surface output state, updated on the PTY delivery queue (off the read
    /// thread) and drained by `processMonitors` on a timer. Kept off `lock` (its own tiny
    /// lock) so the hot output path never contends with layout mutations.
    struct SurfaceMonitor {
        var sawOutput = false
        var sawBell = false
        var lastOutput = Date()
        /// OSC-aware bell-scan state, carried across PTY chunks (a sequence can split over reads).
        var bellScan: SurfaceRegistry.BellScanState = .normal
        var statusScan = PtyStreamScanner()
        var programStatus = ProgramStatusBook()
        var modeMirror = KeyboardModeMirror()
        var statusDirty = false
        var lastPresentation: ProgramStatusPresentation?
        var lastNotifiedAt: TimeInterval?
        /// Stamped at spawn so the first status event can name its session.
        var sessionID: String?
        var tabID: String?
        var ownerPID: Int?
        var ownerName: String?
        var lastProcessSignature: String?
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
        _ = noteSurfaceOutput(surfaceKey: surfaceKey, data: data)
    }

    func programStatusForTesting(surfaceKey: String) -> ProgramStatusBook {
        monitorLock.lock(); defer { monitorLock.unlock() }
        return monitors[surfaceKey]?.programStatus ?? ProgramStatusBook()
    }

    func keyboardModesForTesting(surfaceKey: String) -> TerminalModes {
        monitorLock.lock(); defer { monitorLock.unlock() }
        return monitors[surfaceKey]?.modeMirror.terminalModes ?? TerminalModes()
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

    /// Record output for a surface. Runs on the delivery queue, off the PTY read, and must
    /// not take the registry lock. Returns a program-status query reply to write back, if any.
    /// A real OSC 7501 change is published on the follow stream immediately. The 500 ms
    /// monitor tick still paints the tab; the follow line cannot wait for that tick.
    @discardableResult
    func noteSurfaceOutput(surfaceKey: String, data: Data) -> Data? {
        monitorLock.lock()
        // Moved out (not copied) so mutating its scanner/status containers doesn't copy-on-write
        // them per chunk; re-inserted below before the lock drops.
        var m = monitors.removeValue(forKey: surfaceKey) ?? SurfaceMonitor()
        m.sawOutput = true
        m.lastOutput = Date()
        // Parser-aware bell: a raw `data.contains(0x07)` mistakes the OSC-terminator BEL that shell
        // integration emits on every prompt (OSC 133) for a real terminal bell. The scan threads
        // its state through `m.bellScan` so a sequence spanning chunks is still handled correctly.
        if Self.scanForBell(data, state: &m.bellScan) { m.sawBell = true }
        let before = m.programStatus
        var reply: Data?
        var commandExit: Int?
        var side: [FollowEvent] = []
        var shots: [ProgramStatusBook] = []
        var cursor = before
        for event in m.statusScan.scan(data) {
            m.modeMirror.apply(event)
            if let text = m.programStatus.apply(scan: event) {
                reply = Data(text.utf8)
            }
            if m.programStatus != cursor {
                shots.append(m.programStatus)
                cursor = m.programStatus
            }
            if case let .osc(code, body, _) = event {
                if code == 133, let status = ProgramStatusBook.commandExitCode(body) {
                    commandExit = status
                }
                if let extra = followSideEvent(code: code, body: body, pane: surfaceKey, session: m.sessionID, ownerPID: m.ownerPID, ownerName: m.ownerName) {
                    side.append(extra)
                }
            }
        }
        if m.programStatus != before { m.statusDirty = true }
        let sessionID = m.sessionID
        monitors[surfaceKey] = m
        monitorLock.unlock()
        var prior = before
        for shot in shots {
            emitProgramStatusFollow(before: prior, after: shot, pane: surfaceKey, session: sessionID)
            prior = shot
        }
        for event in side { emitFollow(event) }
        if let commandExit {
            onCommandFinished?(surfaceKey, Int32(commandExit))
        }
        return reply
    }

    /// One follow line per book change, so a chunk that carries `blocked` then `done`
    /// publishes both. OSC 9;4 progress is included until a real report replaces it.
    private func emitProgramStatusFollow(before: ProgramStatusBook, after: ProgramStatusBook, pane: String, session: String?) {
        if after.records.isEmpty, before.acceptedRealReport || after.acceptedRealReport {
            emitFollow(FollowEvent.programStatusRemoved(pane: pane, session: session))
            return
        }
        if after.acceptedRealReport {
            let presentation = ProgramStatusPresenter.decide(
                book: after,
                detector: nil,
                paneName: "Terminal",
                previous: nil,
                now: 0,
                lastNotifiedAt: nil,
                rateLimit: 0
            )
            let state = presentation.mark == .none
                ? (after.records.values.first?.state.rawValue ?? "idle")
                : presentation.mark.rawValue
            emitFollow(FollowEvent.programStatusChanged(
                pane: pane,
                session: session,
                state: state,
                app: presentation.app,
                message: presentation.message
            ))
            if let progress = presentation.progress {
                emitFollow(Self.progressEvent(pane: pane, session: session, progress: progress))
            }
            return
        }
        if let progress = after.records[""]?.progress, progress != before.records[""]?.progress {
            emitFollow(Self.progressEvent(pane: pane, session: session, progress: progress))
        }
    }

    /// Title, directory, and clipboard notices parsed off the same bytes as program status.
    /// Clipboard carries a length. An OSC 52 read (`?`) is not answered and is not an event.
    private func followSideEvent(code: Int, body: String, pane: String, session: String?, ownerPID: Int?, ownerName: String?) -> FollowEvent? {
        var payload: [String: FollowValue] = ["pane": .string(pane)]
        if let session { payload["session"] = .string(session) }
        switch code {
        case 0, 2:
            guard !body.isEmpty, !Self.containsControl(body) else { return nil }
            payload["title"] = .string(body)
            return FollowEvent(type: "terminal.title", payload: payload)
        case 7:
            let url = body.hasPrefix("file://") ? body : HarnessAPI.fileURL(path: body)
            guard !url.isEmpty else { return nil }
            payload["url"] = .string(url)
            if let ownerPID { payload["pid"] = .int(ownerPID) }
            if let ownerName, !ownerName.isEmpty { payload["name"] = .string(ownerName) }
            return FollowEvent(type: "terminal.pwd", payload: payload)
        case 52:
            let data = body.split(separator: ";", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            guard !data.isEmpty, data != "?" else { return nil }
            let length = Data(base64Encoded: data)?.count ?? data.utf8.count
            payload["length"] = .int(length)
            return FollowEvent(type: "terminal.clipboard", payload: payload)
        default:
            return nil
        }
    }

    private static func progressEvent(pane: String, session: String?, progress: Int) -> FollowEvent {
        var payload: [String: FollowValue] = ["pane": .string(pane), "progress": .int(progress)]
        if let session { payload["session"] = .string(session) }
        return FollowEvent(type: "terminal.progress", payload: payload)
    }

    private static func containsControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            return value < 0x20 || value == 0x7F || (value >= 0x80 && value <= 0x9F)
        }
    }

    /// Key tokens encoded with the modes this surface's bytes have set. DECCKM changes
    /// cursor keys only after the mirror has seen the mode; Kitty wins over DECCKM inside
    /// `KeyTokenParser`.
    func encodedKeys(surfaceID: String, keys: [String]) -> Data {
        monitorLock.lock()
        let modes = monitors[surfaceID]?.modeMirror.terminalModes ?? TerminalModes()
        monitorLock.unlock()
        return KeyTokenParser.encode(keys: keys, modes: modes)
    }

    /// Drain the monitor state (timer) and raise activity/silence/bell alerts on non-current
    /// windows, gated on the matching option. Sets the tab flag (surfaced as `#`/`~`/`!` in
    /// `#{window_flags}`) and fires the hook — both only on a real transition.
    private func processMonitors() {
        monitorLock.lock()
        // Idle precheck (monitorLock only): with no fresh output/bell this tick and silence
        // monitoring disarmed, skip the alert drain and the option reads. The foreground
        // process poll still takes the registry lock, so a silent command change emits
        // `terminal.process`. This timer fires twice a second; monitor entries persist
        // after any output, so `drained.isEmpty` alone never gates a session that has
        // produced output. Activity and bell need a fresh flag. Silence needs per-tick
        // idle evaluation only while armed. The orphan sweep still runs, because an entry
        // recreated by a racing PTY read is born with `sawOutput = true`.
        let hasFreshFlags = monitors.contains { $0.value.sawOutput || $0.value.sawBell || $0.value.statusDirty }
        if !hasFreshFlags, !silenceArmed.read() {
            monitorLock.unlock()
            parkIdleSurfacesIfDue()
            lock.lock()
            noteForegroundProcessesLocked()
            lock.unlock()
            return
        }
        monitorFullPasses += 1
        let now = Date()
        var drained: [String: (sawOutput: Bool, sawBell: Bool, idle: TimeInterval, status: ProgramStatusBook?, previous: ProgramStatusPresentation?, lastNotifiedAt: TimeInterval?)] = [:]
        for (key, m) in monitors {
            let status = m.statusDirty ? m.programStatus : nil
            drained[key] = (m.sawOutput, m.sawBell, now.timeIntervalSince(m.lastOutput), status, m.lastPresentation, m.lastNotifiedAt)
            monitors[key]?.sawOutput = false
            monitors[key]?.sawBell = false
            monitors[key]?.statusDirty = false
        }
        monitorLock.unlock()
        parkIdleSurfacesIfDue()
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
            if let book = st.status {
                publishProgramStatusLocked(surfaceKey: key, book: book, previous: st.previous, lastNotifiedAt: st.lastNotifiedAt)
            }
            if st.sawBell { emitBell(surfaceKey: key) }
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
        noteForegroundProcessesLocked()
    }

    /// Publish the presenter's decision onto the tab. Caller holds the registry lock.
    func publishProgramStatusLocked(
        surfaceKey: String,
        book: ProgramStatusBook,
        previous: ProgramStatusPresentation?,
        lastNotifiedAt: TimeInterval?
    ) {
        guard let uuid = UUID(uuidString: surfaceKey) else { return }
        let tab = tabForSurfaceLocked(uuid)
        let detector = tab?.agent.map {
            ProgramStatusDetectorFill(app: $0.kind.rawValue, silent: $0.activity != .working)
        }
        let paneName = (tab?.title.isEmpty == false ? tab?.title : nil) ?? "Terminal"
        let presentation = ProgramStatusPresenter.decide(
            book: book,
            detector: detector,
            paneName: paneName,
            previous: previous,
            now: Date().timeIntervalSinceReferenceDate,
            lastNotifiedAt: lastNotifiedAt,
            rateLimit: 15
        )
        let markChanged = editor.setProgramMark(surfaceID: uuid, mark: Self.programMark(from: presentation))
        var statusChanged = false
        if presentation.fromRealReport, let tab, let match = editor.tab(forSurfaceKey: surfaceKey) {
            let (status, text) = Self.desiredStatus(presentation)
            if tab.status != status || tab.notificationText != text {
                editor.setTabStatus(
                    workspaceID: match.workspaceID,
                    tabID: match.tabID,
                    status: status,
                    notificationText: text
                )
                statusChanged = true
            }
        }
        if markChanged || statusChanged { commit() }
        let notified = presentation.notifications.first
        monitorLock.lock()
        monitors[surfaceKey]?.lastPresentation = presentation
        if notified != nil {
            monitors[surfaceKey]?.lastNotifiedAt = Date().timeIntervalSinceReferenceDate
        }
        monitorLock.unlock()
        if let notified {
            NotificationBus.shared.post(AgentNotification(
                surfaceID: uuid,
                daemonSurfaceID: surfaceKey,
                title: notified.paneName,
                body: notified.body
            ))
        }
    }

    private func tabForSurfaceLocked(_ surfaceID: SurfaceID) -> Tab? {
        for workspace in editor.snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                    return tab
                }
            }
        }
        return nil
    }

    private static func programMark(from presentation: ProgramStatusPresentation) -> ProgramMark? {
        let attention: ProgramMark.Attention
        switch presentation.mark {
        case .none: return nil
        case .working: attention = .working
        case .blocked: attention = .blocked
        case .done: attention = .done
        case .error: attention = .error
        }
        return ProgramMark(
            attention: attention,
            kind: presentation.kind?.rawValue,
            message: presentation.message,
            app: presentation.app,
            progress: presentation.progress,
            fromRealReport: presentation.fromRealReport
        )
    }

    private static func desiredStatus(_ presentation: ProgramStatusPresentation) -> (TabStatus, String?) {
        switch presentation.mark {
        case .blocked: return (.waiting, presentation.message)
        case .error: return (.error, presentation.message)
        case .done: return (.idle, presentation.message)
        case .working, .none: return (.idle, nil)
        }
    }
}
