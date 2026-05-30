import Foundation

/// Formats `SessionSnapshot` queries (sessions / windows / panes) into tmux-style text lines.
/// Shared by `harness-cli`'s `list-sessions`/`list-windows`/`list-panes` subcommands and the
/// control-mode client, so the two never drift in what they report.
public enum SnapshotQueryFormatter {
    /// tmux `list-sessions`: one line per sidebar session, with its window (tab) count.
    public static func sessions(_ snapshot: SessionSnapshot) -> [String] {
        snapshot.workspaces.flatMap(\.sessions).map { session in
            "\(session.id.uuidString): \(displayName(session)) (\(session.tabs.count) windows)"
        }
    }

    /// tmux `list-windows`: every tab across all sessions, index-prefixed (flat enumeration,
    /// matching the control-mode behavior). Pass a session to scope to one session's tabs.
    public static func windows(_ snapshot: SessionSnapshot) -> [String] {
        snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
            .enumerated().map { "\($0.offset): \($0.element.title)" }
    }

    public static func windows(in session: SessionGroup) -> [String] {
        session.tabs.enumerated().map { "\($0.offset): \($0.element.title)" }
    }

    /// tmux `list-panes`: one line per pane in `tab`, index-prefixed in the same order as
    /// `display-panes`/`select-pane`, flagging the active pane.
    public static func panes(in tab: Tab) -> [String] {
        tab.rootPane.allLeaves().enumerated().map { index, leaf in
            let active = leaf.id == tab.activePaneID ? " (active)" : ""
            return "\(index): pane \(leaf.id.uuidString) surface \(leaf.surfaceID.uuidString)\(active)"
        }
    }

    /// Whether a session with this name or UUID exists (`has-session`).
    public static func sessionExists(_ snapshot: SessionSnapshot, nameOrID: String) -> Bool {
        let lowered = nameOrID.lowercased()
        return snapshot.workspaces.flatMap(\.sessions).contains { session in
            session.id.uuidString.lowercased() == lowered || session.name == nameOrID
        }
    }

    /// A non-empty display name for a session (sessions can be unnamed; fall back to the active
    /// tab's title so the line is never blank).
    private static func displayName(_ session: SessionGroup) -> String {
        if !session.name.isEmpty { return session.name }
        return session.activeTab?.title ?? "session"
    }
}
