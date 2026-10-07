import Foundation

/// The one name every surface shows for a session: its own name, or "Session N" (its
/// 1-based position in the workspace) while it has none. The sidebar, switcher, API
/// labels, and CLI target resolution all agree because they all ask here.
public enum SessionDisplayName {
    public static func title(of session: SessionGroup, in workspace: Workspace) -> String {
        title(of: session, among: workspace.sessions)
    }

    public static func title(of session: SessionGroup, among sessions: [SessionGroup]) -> String {
        if !session.name.isEmpty { return session.name }
        let index = (sessions.firstIndex { $0.id == session.id } ?? 0) + 1
        return "Session \(index)"
    }
}
