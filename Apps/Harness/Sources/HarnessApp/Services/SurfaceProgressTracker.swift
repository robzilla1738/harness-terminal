import Foundation
import HarnessCore
import HarnessTerminalEngine

/// Per-surface OSC 9;4 progress state — the terminal-native "program is working" signal
/// (Claude Code 2.0+ keep-alives an indeterminate report across each turn). Ghostty-faithful
/// semantics: ephemeral (never part of the daemon snapshot or layout.json), state 0 clears
/// immediately, and a hardcoded 15s stale timeout — re-armed by every report — cleans up after
/// programs that die without sending the remove. App-local; the tab strip reads `isActive`.
@MainActor
final class SurfaceProgressTracker {
    static let shared = SurfaceProgressTracker()
    /// Ghostty's stale-progress cleanup window. Emitters keep-alive at least ~1/s, so a
    /// surface that goes 15s without a report is treated as no longer reporting.
    static let staleTimeout: TimeInterval = 15

    private var reports: [SurfaceID: TerminalProgressReport] = [:]
    private var staleTimers: [SurfaceID: DispatchWorkItem] = [:]

    /// True while the surface has a live (non-removed, non-stale) progress report in a
    /// state that means "busy". `error`/`paused` are NOT working — showing the working
    /// dot for a stalled or errored agent would say the opposite of the truth.
    func isActive(_ id: SurfaceID) -> Bool {
        guard let state = reports[id]?.state else { return false }
        return state == .set || state == .indeterminate
    }

    /// The determinate progress percent (0–100) when the surface's live report carries one
    /// (`state == .set`); nil for indeterminate/none. The notch HUD renders this on its rows.
    func progressPercent(_ id: SurfaceID) -> Int? {
        guard let report = reports[id], report.state == .set else { return nil }
        return report.value.map { max(0, min(100, $0)) }
    }

    func update(_ report: TerminalProgressReport, forSurface id: SurfaceID) {
        let wasActive = reports[id] != nil
        if report.state == .remove {
            clear(id)
        } else {
            reports[id] = report
            armStaleTimer(id)
        }
        // Refresh the tab strip only on visibility transitions — keep-alive re-asserts
        // (~1/s per working agent) are free.
        if wasActive != (reports[id] != nil) { nudgeMetadataRefresh() }
    }

    /// Drop a surface's state when its pane goes away (no point keeping a timer alive).
    func forget(_ id: SurfaceID) {
        let wasActive = reports[id] != nil
        clear(id)
        if wasActive { nudgeMetadataRefresh() }
    }

    private func clear(_ id: SurfaceID) {
        reports[id] = nil
        staleTimers[id]?.cancel()
        staleTimers[id] = nil
    }

    private func armStaleTimer(_ id: SurfaceID) {
        staleTimers[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.reports[id] != nil else { return }
            self.clear(id)
            self.nudgeMetadataRefresh()
        }
        staleTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.staleTimeout, execute: work)
    }

    /// Same metadata-only nudge the rest of the app uses to refresh tab pills in place.
    private func nudgeMetadataRefresh() {
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: [
                "revision": SessionCoordinator.shared.snapshot.revision,
                "structureChanged": false,
                "metadataOnly": true,
            ]
        )
    }
}
