import Foundation

/// One row in the command menu or the session switcher. The panels paint these;
/// they do not keep a second copy of the titles and shortcuts.
public struct ChromeMenuRow: Equatable, Sendable {
    public var id: String
    public var title: String
    public var shortcut: String
    public var selected: Bool
    public var current: Bool

    public init(id: String, title: String, shortcut: String, selected: Bool, current: Bool) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.selected = selected
        self.current = current
    }
}

public enum ChromeMenus {
    /// Shipped command-menu actions, in menu order. `selectedID` marks the filled row.
    public static func commandRows(selectedID: String? = nil) -> [ChromeMenuRow] {
        let specs: [(String, String, String)] = [
            ("action.newSession", "New Session", "⇧⌘N"),
            ("action.newTab", "New Tab", "⌘T"),
            ("action.splitH", "Split Horizontal", "⌘D"),
            ("action.splitV", "Split Vertical", "⇧⌘D"),
            ("action.zoomPane", "Zoom Pane", "Prefix z"),
            ("action.killPane", "Kill Pane", "Prefix x"),
            ("action.copyMode", "Toggle Copy Mode", "Prefix ["),
            ("action.renameTab", "Rename Active Tab", "Prefix ,"),
            ("action.installCLI", "Install harness-cli to PATH", ""),
            ("action.settings", "Open Settings", "⌘,"),
            ("action.reimport", "Re-import Terminal Config", "Prefix r"),
            ("nav.jumpNotification", "Jump to Notification", "⇧⌘U"),
            ("nav.prevTab", "Previous Tab", "⇧⌘["),
            ("nav.nextTab", "Next Tab", "⇧⌘]"),
            ("nav.cyclePane", "Cycle Pane", "Prefix o"),
            ("action.changeSession", "Change Session", "⌃⌘S"),
            ("action.addRemoteHost", "Add Remote Host…", ""),
        ]
        return specs.map { id, title, shortcut in
            ChromeMenuRow(
                id: id,
                title: title,
                shortcut: shortcut,
                selected: id == selectedID,
                current: false
            )
        }
    }

    /// Sessions for the switcher, then the existing new-session and add-remote actions.
    /// The current session is marked. `selectedID` fills that row.
    public static func sessionRows(
        sessions: [(id: String, title: String)],
        currentID: String?,
        selectedID: String? = nil
    ) -> [ChromeMenuRow] {
        var rows = sessions.map { session in
            ChromeMenuRow(
                id: session.id,
                title: session.title,
                shortcut: "",
                selected: session.id == selectedID,
                current: session.id == currentID
            )
        }
        for id in ["action.newSession", "action.addRemoteHost"] {
            if let action = commandRows().first(where: { $0.id == id }) {
                rows.append(ChromeMenuRow(
                    id: action.id,
                    title: action.title,
                    shortcut: action.shortcut,
                    selected: action.id == selectedID,
                    current: false
                ))
            }
        }
        return rows
    }
}

/// A session the switcher can list. `owner` is the daemon it lives on (`DaemonSidebar.localID`
/// for this Mac); `ownerTitle` is how that daemon is labeled ("This Mac", "devbox").
public struct SwitcherSession: Equatable, Sendable {
    public var id: String
    public var title: String
    public var owner: String
    public var ownerTitle: String

    public init(id: String, title: String, owner: String, ownerTitle: String) {
        self.id = id
        self.title = title
        self.owner = owner
        self.ownerTitle = ownerTitle
    }
}

public enum SwitcherItem: Equatable, Sendable {
    /// Daemon group label, shown only when more than one daemon has sessions.
    case header(String)
    /// A session (`owner` set) or an action (`owner` nil). Actions carry their shortcut.
    case row(ChromeMenuRow, owner: String?)
    case separator

    public var row: ChromeMenuRow? {
        if case let .row(row, _) = self { return row }
        return nil
    }
}

/// The session popover's rows: filtered sessions (grouped by daemon when there are several),
/// a "Create" row when the filter names no session, then New Session and Add Remote Host.
public enum SessionSwitcherModel {
    public static let createID = "action.createSession"
    public static let newSessionID = "action.newSession"
    public static let addRemoteHostID = "action.addRemoteHost"

    public static func items(sessions: [SwitcherSession], currentID: String?, query: String) -> [SwitcherItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = needle.isEmpty
            ? sessions
            : sessions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        var items: [SwitcherItem] = []
        var owners: [String] = []
        for session in matches where !owners.contains(session.owner) { owners.append(session.owner) }
        let grouped = Set(sessions.map(\.owner)).count > 1
        for owner in owners {
            let group = matches.filter { $0.owner == owner }
            if grouped, let title = group.first?.ownerTitle { items.append(.header(title)) }
            for session in group {
                items.append(.row(
                    ChromeMenuRow(id: session.id, title: session.title, shortcut: "", selected: false, current: session.id == currentID),
                    owner: session.owner
                ))
            }
        }
        let exact = sessions.contains { $0.title.caseInsensitiveCompare(needle) == .orderedSame }
        if !needle.isEmpty, !exact {
            items.append(.row(
                ChromeMenuRow(id: createID, title: "Create \u{201C}\(needle)\u{201D}", shortcut: "↩", selected: false, current: false),
                owner: nil
            ))
        }
        let actions = ChromeMenus.commandRows()
        for id in [newSessionID, addRemoteHostID] {
            guard let action = actions.first(where: { $0.id == id }) else { continue }
            if !items.isEmpty { items.append(.separator) }
            items.append(.row(action, owner: nil))
        }
        return items
    }

    /// Index of the next selectable row from `index` in `direction` (+1 / -1), wrapping.
    public static func step(_ items: [SwitcherItem], from index: Int?, by direction: Int) -> Int? {
        let selectable = items.indices.filter { items[$0].row != nil }
        guard !selectable.isEmpty else { return nil }
        guard let index, let position = selectable.firstIndex(of: index) else {
            return direction >= 0 ? selectable.first : selectable.last
        }
        let next = (position + direction + selectable.count) % selectable.count
        return selectable[next]
    }

    /// Where the highlight starts: the create row while typing a new name, else the first
    /// matching session, else the current session.
    public static func initialSelection(_ items: [SwitcherItem], query: String, currentID: String?) -> Int? {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let firstSession = items.firstIndex { if case .row(_, owner: .some) = $0 { return true }; return false }
            return firstSession ?? items.firstIndex { $0.row?.id == createID }
        }
        return items.firstIndex { $0.row?.current == true } ?? items.firstIndex { $0.row != nil }
    }
}
