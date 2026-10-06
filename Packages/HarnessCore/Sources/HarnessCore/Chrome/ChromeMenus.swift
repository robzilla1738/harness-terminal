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
            ("action.changeSession", "Change Session", ""),
            ("action.addRemoteHost", "Add Remote Host...", ""),
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
