import AppKit
import Combine
import Foundation
import HarnessCore
import SwiftUI

enum AgentNotchPresentation: Equatable {
    case closed
    /// Transient one-row live activity (agent needs input / finished / errored).
    /// Auto-dismisses; hover promotes it to `.open`.
    case peek(AgentNotchPeekEvent)
    case open
}

@MainActor
final class AgentNotchViewModel: ObservableObject {
    @Published private(set) var presentation: AgentNotchPresentation = .closed
    @Published private(set) var geometry: NotchLayoutMetrics = NotchGeometry.fallback
    @Published private(set) var agents: [AgentSessionSummary] = []
    @Published private(set) var rows: [AgentNotchRowSummary] = []
    @Published private(set) var openOnHover = true
    @Published private(set) var sessionCount = 0
    /// Determinate OSC 9;4 percent per row id, when an agent reports one (build tools do;
    /// Claude Code keep-alives indeterminate). Rendered as "working · 47%" + underline bar.
    @Published private(set) var rowProgress: [String: Int] = [:]

    private var hoverTask: Task<Void, Never>?
    private var peekDismissTask: Task<Void, Never>?
    private var isHovering = false
    private let maximumVisibleRows = 8
    /// Hover must be deliberate: a fly-by across the menu bar should never open the HUD.
    /// 400 ms dwell (skill guidance 250–600 ms); tap still opens instantly.
    private let hoverOpenDelay: UInt64 = 400_000_000
    private let hoverCloseDelay: UInt64 = 190_000_000
    private let peekDuration: Duration = .milliseconds(2_500)
    /// Per-row peek cooldown so a flapping detector can't strobe the notch.
    private let peekCooldown: TimeInterval = 10
    private var peekStates: [String: AgentNotchPeekDecider.RowState]?
    private var lastPeekAt: [String: Date] = [:]

    var isOpen: Bool {
        if case .open = presentation { return true }
        return false
    }

    var isPeeking: Bool {
        if case .peek = presentation { return true }
        return false
    }

    var waitingCount: Int {
        rows.reduce(0) { $0 + $1.waitingCount }
    }

    var workingCount: Int {
        rows.filter(\.isWorking).count
    }

    var agentCount: Int {
        rows.filter { $0.agentKind != nil }.count
    }

    var visibleRows: [AgentNotchRowSummary] {
        Array(rows.prefix(maximumVisibleRows))
    }

    var hasOverflowRows: Bool {
        rows.count > maximumVisibleRows
    }

    var headerSummary: String {
        AgentNotchProjection.headerSummary(
            workingCount: workingCount,
            waitingCount: waitingCount,
            sessionCount: sessionCount
        )
    }

    var openContentHeight: CGFloat {
        let rowCount = max(1, visibleRows.count)
        let rowHeight: CGFloat = 38
        let rowSpacing: CGFloat = 5
        let headerHeight: CGFloat = 30
        let sectionSpacing: CGFloat = 6
        let verticalPadding: CGFloat = 20
        let overflowHint: CGFloat = hasOverflowRows ? 18 : 0
        let rowStack = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * rowSpacing
        let ideal = verticalPadding + headerHeight + sectionSpacing + rowStack + overflowHint
        let minimum = rows.isEmpty ? CGFloat(86) : CGFloat(98)
        return min(CGFloat(geometry.openHeight), max(minimum, ideal.rounded(.up)))
    }

    // MARK: - Motion

    /// Asymmetric springs (skill: open livelier, close fully damped); Reduce Motion → fades.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var openAnimation: Animation {
        // Calm, barely-damped grow (utility HUD, not a bouncy toy): a touch more damping than
        // before so the shape settles without overshoot.
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.36, dampingFraction: 0.86)
    }

    var closeAnimation: Animation {
        // Snappy, fully damped collapse. Kept close to the content-fade so the pill never lingers
        // empty while the shape is still shrinking.
        reduceMotion ? .easeOut(duration: 0.10) : .spring(response: 0.30, dampingFraction: 1.0)
    }

    /// In-place changes while already presented (a row appearing/leaving, a badge or count
    /// updating). The single driver for content animation: applied in `refreshFromCoordinator`
    /// so the view carries no implicit `.animation(value:)` of its own (two competing drivers
    /// were a glitch source). Presentation changes use the open/close springs above instead.
    var contentAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 0.88)
    }

    func updateGeometry(_ geometry: NotchLayoutMetrics) {
        self.geometry = geometry
    }

    // MARK: - Data refresh

    func refreshFromCoordinator() {
        let coordinator = SessionCoordinator.shared
        openOnHover = coordinator.settings.notchOpenOnHover
        let currentAgents = coordinator.agentsList()
        var updatedRows = AgentNotchProjection.rows(from: coordinator.snapshot, agents: currentAgents)
        // Reconcile OSC 9;4 progress state with detector-driven activity. The projection
        // derives agentActivity from the daemon snapshot (AgentDetector), which Claude Code
        // doesn't keep at .working between turns. SurfaceProgressTracker is the
        // terminal-native signal (OSC 9;4); promote a row to .working when any of its tab's
        // surfaces has an active progress report, so the notch agrees with the tab-bar dot.
        let tracker = SurfaceProgressTracker.shared
        let tabSurfaces: [UUID: [SurfaceID]] = coordinator.snapshot.workspaces
            .flatMap(\.sessions)
            .flatMap(\.tabs)
            .reduce(into: [:]) { map, tab in
                map[tab.id] = tab.rootPane.allSurfaceIDs()
            }
        var progress: [String: Int] = [:]
        for i in updatedRows.indices {
            guard let tabID = updatedRows[i].tabID, let surfaces = tabSurfaces[tabID] else { continue }
            // OSC 9;4 promotes an idle/working row to .working, but must never override a waiting
            // or errored agent: one that needs your input (or has errored) is not "working", even
            // if a stale progress report lingers. Otherwise the same agent reads as both
            // "waiting" and "working" at once.
            if updatedRows[i].waitingCount == 0,
               updatedRows[i].agentActivity != .errored,
               surfaces.contains(where: { tracker.isActive($0) }) {
                updatedRows[i].agentActivity = .working
            }
            if let percent = surfaces.compactMap({ tracker.progressPercent($0) }).first {
                progress[updatedRows[i].id] = percent
            }
        }
        let sortedAgents = AgentNotchProjection.sortedAgents(currentAgents)
        let newSessionCount = Set(updatedRows.map(\.sessionID)).count

        // Publish only when something the HUD actually shows changed. A snapshot tick fires on any
        // metadata update (cwd, git, agent activity elsewhere); without this guard the open list
        // re-renders — and re-diffs its TimelineView — on every one, which reads as jitter.
        guard sortedAgents != agents
            || updatedRows != rows
            || progress != rowProgress
            || newSessionCount != sessionCount
        else {
            considerPeek()
            return
        }

        // One explicit driver for the in-place change, so it animates smoothly without competing
        // with the presentation springs (or with implicit view animations, which are now gone).
        withAnimation(contentAnimation) {
            agents = sortedAgents
            rows = updatedRows
            rowProgress = progress
            sessionCount = newSessionCount
        }
        considerPeek()
    }

    // MARK: - Peek

    /// Diff this refresh against the last one and surface at most one peek-worthy
    /// transition. Suppressed while Harness is frontmost (the user already sees the tab
    /// dot), while the HUD is open, and per-row for `peekCooldown` after a peek.
    private func considerPeek() {
        let (events, next) = AgentNotchPeekDecider.decide(previous: peekStates, rows: rows)
        peekStates = next
        guard !events.isEmpty, !isOpen, !NSApp.isActive else { return }
        let now = Date()
        guard let event = events.first(where: { event in
            guard let last = lastPeekAt[event.row.id] else { return true }
            return now.timeIntervalSince(last) >= peekCooldown
        }) else { return }
        lastPeekAt[event.row.id] = now
        showPeek(event)
    }

    private func showPeek(_ event: AgentNotchPeekEvent) {
        withAnimation(openAnimation) { presentation = .peek(event) }
        armPeekDismiss(after: peekDuration)
    }

    private func armPeekDismiss(after duration: Duration) {
        peekDismissTask?.cancel()
        peekDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isPeeking else { return }
                self.close()
            }
        }
    }

    // MARK: - Hover

    func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        isHovering = hovering
        if hovering {
            // Hovering a peek keeps it alive and promotes it to the full HUD after the dwell.
            if isPeeking { peekDismissTask?.cancel() }
            guard openOnHover, !isOpen else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.hoverOpenDelay ?? 0)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.isHovering else { return }
                    self.open()
                }
            }
        } else {
            // Leaving a peek lets it finish on a short fuse instead of the full duration.
            if isPeeking {
                armPeekDismiss(after: .milliseconds(800))
                return
            }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.hoverCloseDelay ?? 0)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !self.isHovering else { return }
                    self.close()
                }
            }
        }
    }

    // MARK: - Presentation

    func open() {
        peekDismissTask?.cancel()
        refreshFromCoordinator()
        withAnimation(openAnimation) { presentation = .open }
    }

    func close() {
        peekDismissTask?.cancel()
        withAnimation(closeAnimation) { presentation = .closed }
    }

    func toggleOpen() {
        isOpen ? close() : open()
    }

    func openRow(_ row: AgentNotchRowSummary) {
        let coordinator = SessionCoordinator.shared
        coordinator.selectWorkspace(row.workspaceID)
        coordinator.selectSession(workspaceID: row.workspaceID, sessionID: row.sessionID)
        if let tabID = row.tabID {
            coordinator.selectTab(workspaceID: row.workspaceID, tabID: tabID)
        }
        AgentNotchWindowActivator.bringHarnessToFront()
        close()
    }
}

@MainActor
enum AgentNotchWindowActivator {
    static func bringHarnessToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // A hidden app (⌘H) must be unhidden before any window can come forward.
        if NSApp.isHidden { NSApp.unhide(nil) }
        // Candidate terminal windows (never the notch/quick-terminal panels). Prefer one that's
        // minimized into the Dock — that's the case `makeKeyAndOrderFront` alone can't handle, and
        // a miniaturized window can report `canBecomeMain == false`, so don't filter on it here.
        let windows = NSApp.windows.filter { !($0 is NSPanel) }
        guard let target = windows.first(where: { $0.isMiniaturized })
            ?? windows.first(where: { $0.canBecomeMain })
            ?? windows.first
        else { return }
        // `makeKeyAndOrderFront` only reorders an on-screen/background window; a Dock-minimized
        // window must be deminiaturized first. This makes a notch-row click restore the terminal
        // whether it was backgrounded OR minimized.
        if target.isMiniaturized { target.deminiaturize(nil) }
        target.makeKeyAndOrderFront(nil)
    }
}
