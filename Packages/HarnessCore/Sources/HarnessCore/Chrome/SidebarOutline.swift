import Foundation

/// One line of the sidebar: a daemon heading (only when several daemons are visible),
/// a session heading, or a tab under its session. Sessions on another daemon have no
/// tabs here; selecting one reconnects to that daemon.
public enum SidebarOutlineLine: Equatable, Sendable {
    case machine(title: String, detail: String)
    case session(id: String, title: String, owner: String, live: Bool, current: Bool)
    case tab(sessionID: String, tabID: String, selected: Bool)

    public var isSelectable: Bool {
        if case .machine = self { return false }
        return true
    }
}

public enum SidebarOutline {
    /// `groups` are the daemon boards (`SessionCoordinator.sidebarGroups()`); `live` are the
    /// sessions of the daemon this window is attached to (`liveOwner`). `query` filters by
    /// session name, tab title, and directory; a session whose name matches keeps all tabs.
    public static func lines(
        groups: [DaemonSidebarGroup],
        liveOwner: String,
        live: [SessionGroup],
        activeSessionID: SessionID?,
        query: String = "",
        sessionTitle: (SessionGroup) -> String
    ) -> [SidebarOutlineLine] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let showMachines = groups.count > 1
        // The attached daemon always lists its sessions, even before its board is recorded.
        var boards = groups
        if !boards.contains(where: { $0.id == liveOwner }) {
            boards.insert(DaemonSidebarGroup(id: liveOwner, title: liveOwner, detail: "", local: false, sessions: []), at: 0)
        }
        var lines: [SidebarOutlineLine] = []
        for group in boards {
            var block: [SidebarOutlineLine] = []
            let hostHit = needle.isEmpty || group.title.lowercased().contains(needle) || group.id.lowercased().contains(needle)
            if group.id == liveOwner {
                for session in live {
                    let title = sessionTitle(session)
                    let nameHit = hostHit || title.lowercased().contains(needle)
                    let tabs = session.tabs.filter { tab in
                        nameHit || tab.title.lowercased().contains(needle) || tab.cwd.lowercased().contains(needle)
                    }
                    guard nameHit || !tabs.isEmpty else { continue }
                    let current = session.id == activeSessionID
                    block.append(.session(id: session.id.uuidString, title: title, owner: liveOwner, live: true, current: current))
                    for tab in tabs {
                        block.append(.tab(
                            sessionID: session.id.uuidString,
                            tabID: tab.id.uuidString,
                            selected: current && tab.id == session.activeTabID
                        ))
                    }
                }
            } else {
                for row in group.sessions where hostHit || row.name.lowercased().contains(needle) {
                    block.append(.session(id: row.id, title: row.name, owner: row.owner, live: false, current: false))
                }
            }
            guard !block.isEmpty else { continue }
            if showMachines { lines.append(.machine(title: group.title, detail: group.detail)) }
            lines += block
        }
        return lines
    }
}
