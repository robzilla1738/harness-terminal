import AppKit
import HarnessCore

/// What one window shows: a session on one daemon (this Mac's or a remote host's). The key
/// window's daemon is the active daemon and its session the active session (becoming key
/// selects both, and an outside `select-session` moves the key window), so every action that
/// works on "the active tab" works on the window in front. Other windows keep showing their
/// own session, live, on their own daemon. A session shows in one window at a time: its panes
/// can only be in one place.
@MainActor
final class WindowContext {
    /// The session this window shows; nil until the first snapshot, then the active one.
    private(set) var sessionID: SessionID?
    /// The daemon it lives on: `DaemonSidebar.localID` or a remote host's name.
    private(set) var owner: String
    weak var window: NSWindow?

    init(sessionID: SessionID? = nil, owner: String = DaemonSidebar.localID) {
        self.sessionID = sessionID
        self.owner = owner
    }

    /// Whether this window speaks for the active daemon's active session: it's on the active
    /// daemon and it's key, or it's the only window (no key status yet, at launch or behind
    /// another app). A window not yet on screen keeps the session it was opened for.
    var followsActiveSession: Bool {
        guard owner == SessionCoordinator.shared.activeOwner else { return false }
        guard let window else { return sessionID == nil }
        return window.isKeyWindow || WindowContexts.all.count <= 1
    }

    /// The latest snapshot of this window's daemon.
    var snapshot: SessionSnapshot { SessionCoordinator.shared.snapshot(for: owner) }

    var session: SessionGroup? {
        let snapshot = snapshot
        guard let sessionID else { return snapshot.activeWorkspace?.activeSession }
        return snapshot.workspaces.lazy.flatMap(\.sessions).first { $0.id == sessionID }
    }

    var workspace: Workspace? {
        let snapshot = snapshot
        guard let sessionID else { return snapshot.activeWorkspace }
        return snapshot.workspaces.first { $0.sessions.contains { $0.id == sessionID } }
    }

    /// The tab on screen: the session's active tab.
    var tab: Tab? {
        guard let session else { return nil }
        return session.activeTab ?? session.tabs.first
    }

    /// Bring this context up to date with its daemon's snapshot. Returns false when this
    /// window's session (or its daemon) is gone and the window should close. Detaching a daemon
    /// never closes every window: when no window is on another attached daemon, the first of
    /// its windows moves to the active one (the others close).
    func update() -> Bool {
        let coordinator = SessionCoordinator.shared
        if !coordinator.isConnected(owner) {
            let open = WindowContexts.all.filter { $0.window != nil }
            let anotherStays = open.contains { $0 !== self && coordinator.isConnected($0.owner) }
            let firstOrphan = open.first { !coordinator.isConnected($0.owner) }
            guard !anotherStays, firstOrphan === self else { return false }
            owner = coordinator.activeOwner
            sessionID = nil
        }
        let snapshot = snapshot
        if followsActiveSession || (sessionID == nil && owner == coordinator.activeOwner),
           let active = snapshot.activeWorkspace?.activeSessionID {
            // Never take a session another window is showing (it was just opened there).
            if WindowContexts.all.contains(where: { $0 !== self && $0.sessionID == active }) {
                return sessionID == nil || session != nil
            }
            sessionID = active
            return true
        }
        return session != nil
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
