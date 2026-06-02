import AppKit
import Combine
import Foundation
import HarnessCore

enum AgentNotchPresentation: Equatable {
    case closed
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

    private var hoverTask: Task<Void, Never>?
    private var isHovering = false
    private let maximumVisibleRows = 8

    var isOpen: Bool {
        if case .open = presentation { return true }
        return false
    }

    var waitingCount: Int {
        rows.reduce(0) { $0 + $1.waitingCount }
    }

    var workingCount: Int {
        rows.filter { $0.agentActivity == .working }.count
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

    func updateGeometry(_ geometry: NotchLayoutMetrics) {
        self.geometry = geometry
    }

    func refreshFromCoordinator() {
        let coordinator = SessionCoordinator.shared
        openOnHover = coordinator.settings.notchOpenOnHover
        let currentAgents = coordinator.agentsList()
        agents = AgentNotchProjection.sortedAgents(currentAgents)
        rows = AgentNotchProjection.rows(from: coordinator.snapshot, agents: currentAgents)
        sessionCount = Set(rows.map(\.sessionID)).count
    }

    func handleHover(_ hovering: Bool) {
        hoverTask?.cancel()
        guard openOnHover else { return }
        isHovering = hovering
        if hovering {
            guard !isOpen else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.isHovering else { return }
                    self.open()
                }
            }
        } else {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 190_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, !self.isHovering else { return }
                    self.close()
                }
            }
        }
    }

    func open() {
        refreshFromCoordinator()
        presentation = .open
    }

    func close() {
        presentation = .closed
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
        for window in NSApp.windows where window.canBecomeMain && !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
