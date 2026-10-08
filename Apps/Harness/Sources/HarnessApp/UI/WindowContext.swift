import AppKit
import HarnessCore

/// What one window shows: a session. The key window's session is always the daemon's active
/// session (becoming key selects it, and an outside `select-session` moves the key window),
/// so every action that works on "the active tab" works on the window in front. Other
/// windows keep showing their own session. A session shows in one window at a time: its
/// panes can only be in one place.
@MainActor
final class WindowContext {
    /// The session this window shows; nil until the first snapshot, then the active one.
    private(set) var sessionID: SessionID?
    weak var window: NSWindow?

    init(sessionID: SessionID? = nil) {
        self.sessionID = sessionID
    }

    /// Whether this window speaks for the daemon's active session: it's key, or it's the only
    /// window (a window with no key status yet, at launch or behind another app).
    var followsActiveSession: Bool {
        guard let window else { return true }
        return window.isKeyWindow || WindowContexts.all.count <= 1
    }

    func session(in snapshot: SessionSnapshot) -> SessionGroup? {
        guard let sessionID else { return snapshot.activeWorkspace?.activeSession }
        return snapshot.workspaces.lazy.flatMap(\.sessions).first { $0.id == sessionID }
    }

    func workspace(in snapshot: SessionSnapshot) -> Workspace? {
        guard let sessionID else { return snapshot.activeWorkspace }
        return snapshot.workspaces.first { $0.sessions.contains { $0.id == sessionID } }
    }

    /// The tab on screen: the session's active tab.
    func tab(in snapshot: SessionSnapshot) -> Tab? {
        guard let session = session(in: snapshot) else { return nil }
        return session.activeTab ?? session.tabs.first
    }

    /// Bring this context up to date with `snapshot`. Returns false when this window's session
    /// is gone and the window should close.
    func update(from snapshot: SessionSnapshot) -> Bool {
        if followsActiveSession || sessionID == nil, let active = snapshot.activeWorkspace?.activeSessionID {
            // Never take a session another window is showing (it was just opened there).
            if WindowContexts.all.contains(where: { $0 !== self && $0.sessionID == active }) {
                return sessionID == nil || session(in: snapshot) != nil
            }
            sessionID = active
            return true
        }
        return session(in: snapshot) != nil
    }

    /// Show `session` here (not while another window shows it).
    func show(_ session: SessionID) {
        sessionID = session
    }
}

/// Every open window's context, so a session opens where it's already showing.
@MainActor
enum WindowContexts {
    private static var contexts: [WeakContext] = []

    private struct WeakContext { weak var context: WindowContext? }

    static var all: [WindowContext] {
        contexts.removeAll { $0.context == nil }
        return contexts.compactMap(\.context)
    }

    static func register(_ context: WindowContext) {
        contexts.append(WeakContext(context: context))
    }

    /// The window already showing `session`, if any.
    static func window(showing session: SessionID) -> NSWindow? {
        all.first { $0.sessionID == session && $0.window != nil }?.window
    }
}
