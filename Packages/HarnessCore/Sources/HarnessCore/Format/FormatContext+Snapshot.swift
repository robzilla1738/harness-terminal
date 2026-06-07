import Foundation

extension FormatContext {
    /// Fill the snapshot-derived metadata fields that every frontend computes the
    /// same way, so the daemon and the attach-client compositor can't drift apart.
    ///
    /// This is deliberately the *shared* subset only. Each caller layers its own
    /// vantage-point facts on top afterward: the daemon adds live PTY probes
    /// (`panePID`, live width/height, `historyBytes`, `serverPID`, `sessionAttached`)
    /// and the compositor adds client tty facts (`clientWidth`/`clientHeight`,
    /// `clientTTY`, `clientTermname`). Fields whose logic genuinely differs between
    /// the two sites — `paneActive`, `sessionName` empty-handling, the base-index
    /// offsets, `paneCurrentCommand` — stay at the call sites by design.
    ///
    /// `snapshot` is optional to preserve the compositor's behavior: before the first
    /// layout snapshot arrives it has none, and in that window `sessionGroup` must stay
    /// unset rather than be synthesized from an empty snapshot.
    public mutating func applySnapshotMetadata(
        tab: Tab?,
        session: SessionGroup?,
        snapshot: SessionSnapshot?
    ) {
        paneDead = tab.map { $0.exitStatus != nil }
        paneExitStatus = tab?.exitStatus
        sessionID = session?.id.uuidString
        windowID = tab?.id.uuidString
        sessionWindows = session?.tabs.count
        windowPanes = tab?.rootPane.allPaneIDs().count
        if let tab, let session { windowActive = tab.id == session.activeTabID }
        if let snapshot {
            sessionGroup = session.flatMap { snapshot.groupName(of: $0) }
        }
    }
}
