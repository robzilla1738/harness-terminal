import AppKit
import HarnessCore

/// Shared mapping from a tab's agent state to the small activity dot shown on tab pills, sidebar
/// session rows, and (conceptually) the notch — so every surface reads the same:
/// working = a breathing brand-color dot, needs-you = amber, just-finished = a brief green check.
@MainActor
enum AgentActivityIndicator {
    /// The dot style for a tab's current agent activity, or nil when nothing should show
    /// (plain idle with no recent finish).
    static func dotStyle(for tab: Tab) -> StatusDotView.Style? {
        let kind = tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title)
        switch tab.agent?.activity {
        case .working:
            // Empty hex falls back to the accent inside StatusDotView.
            let hex = kind.map { SessionCoordinator.shared.settings.agentColorHex(for: $0) } ?? ""
            return .agentWorking(hex: hex)
        case .awaiting:
            return .attention
        default:
            break
        }
        if tab.status == .waiting { return .attention }
        if AgentFinishTracker.shared.justFinished(tab.id) { return .done }
        return nil
    }

    /// The aggregate dot style for a session (any tab working → working; any awaiting/waiting →
    /// attention; any just-finished → done), or nil when idle. Surfaces the most "alive" state so a
    /// collapsed session row reflects what's happening across its tabs.
    static func dotStyle(forSession session: SessionGroup) -> StatusDotView.Style? {
        var sawAttention = false
        var sawDone = false
        for tab in session.tabs {
            switch dotStyle(for: tab) {
            case .agentWorking(let hex): return .agentWorking(hex: hex) // working wins outright
            case .attention: sawAttention = true
            case .done: sawDone = true
            default: break
            }
        }
        if sawAttention { return .attention }
        if sawDone { return .done }
        return nil
    }
}

/// Records when an agent transitions working → idle (a clean finish, not "awaiting input") so the
/// UI can show a brief green check before settling. App-local and ephemeral — never part of the
/// daemon snapshot. Auto-clears after `window`, nudging a metadata refresh so the check fades.
@MainActor
final class AgentFinishTracker {
    static let shared = AgentFinishTracker()
    /// How long the "just finished" check shows.
    static let window: TimeInterval = 2.5

    private var finishedAt: [TabID: Date] = [:]
    private var clearScheduled: Set<TabID> = []

    func noteFinished(tabID: TabID) {
        finishedAt[tabID] = Date()
        scheduleClear(tabID, after: Self.window + 0.05)
    }

    func justFinished(_ tabID: TabID) -> Bool {
        guard let at = finishedAt[tabID] else { return false }
        if Date().timeIntervalSince(at) > Self.window {
            finishedAt[tabID] = nil
            return false
        }
        return true
    }

    /// Clear after the window elapses, but self-correct: if a *newer* finish reset the window while
    /// this timer was pending, reschedule for the remaining time rather than clearing early.
    private func scheduleClear(_ tabID: TabID, after delay: TimeInterval) {
        guard !clearScheduled.contains(tabID) else { return }
        clearScheduled.insert(tabID)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.clearScheduled.remove(tabID)
            guard let at = self.finishedAt[tabID] else { return }
            let remaining = Self.window - Date().timeIntervalSince(at)
            if remaining > 0.01 {
                self.scheduleClear(tabID, after: remaining + 0.05)
                return
            }
            self.finishedAt[tabID] = nil
            // The check is driven off snapshot refreshes; nudge one so it disappears on time.
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
}
