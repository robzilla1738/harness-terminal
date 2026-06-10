import Foundation

public struct SessionEditor: Sendable {
    public var snapshot: SessionSnapshot

    public init(snapshot: SessionSnapshot = SessionSnapshot()) {
        self.snapshot = snapshot
    }

    private mutating func bumpRevision() {
        snapshot.revision += 1
        snapshot.savedAt = .now
    }

    public mutating func addWorkspace(name: String) -> WorkspaceID {
        let workspace = Workspace(name: name, sortOrder: snapshot.workspaces.count)
        snapshot.workspaces.append(workspace)
        snapshot.activeWorkspaceID = workspace.id
        bumpRevision()
        return workspace.id
    }

    public func resolveWorkspaceID(nameOrID: String) -> WorkspaceID? {
        if let uuid = UUID(uuidString: nameOrID),
           snapshot.workspaces.contains(where: { $0.id == uuid })
        {
            return uuid
        }
        return snapshot.workspaces.first { $0.name == nameOrID }?.id
    }

    public mutating func addSession(to workspaceID: WorkspaceID, cwd: String? = nil, name: String? = nil) -> SessionID? {
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return nil
        }
        let tab = Tab(cwd: existingWorkingDirectory(cwd))
        let session = SessionGroup(
            name: name ?? "",
            tabs: [tab],
            activeTabID: tab.id,
            sortOrder: snapshot.workspaces[workspaceIndex].sessions.count
        )
        snapshot.workspaces[workspaceIndex].sessions.append(session)
        snapshot.workspaces[workspaceIndex].activeSessionID = session.id
        bumpRevision()
        return session.id
    }

    public mutating func addTab(to workspaceID: WorkspaceID, cwd: String? = nil) -> TabID? {
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return nil
        }
        if snapshot.workspaces[workspaceIndex].sessions.isEmpty {
            _ = addSession(to: workspaceID, cwd: cwd)
            return snapshot.workspaces[workspaceIndex].activeTab?.id
        }
        let activeSessionID = snapshot.workspaces[workspaceIndex].activeSessionID
        let sessionIndex = snapshot.workspaces[workspaceIndex].sessions.firstIndex { $0.id == activeSessionID } ?? 0
        let tab = Tab(
            cwd: existingWorkingDirectory(cwd),
            sortOrder: snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.count
        )
        snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.append(tab)
        snapshot.workspaces[workspaceIndex].sessions[sessionIndex].activeTabID = tab.id
        snapshot.workspaces[workspaceIndex].activeSessionID = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].id
        bumpRevision()
        return tab.id
    }

    public mutating func splitPane(
        in workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID,
        direction: SplitDirection
    ) -> PaneID? {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return nil }

        var tab = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex]
        guard let newPaneID = split(node: &tab.rootPane, targetPaneID: paneID, direction: direction) else {
            return nil
        }
        // Focus follows the split, tmux-style: the new pane becomes active.
        tab.lastActivePaneID = tab.activePaneID
        tab.activePaneID = newPaneID
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex] = tab
        bumpRevision()
        return newPaneID
    }

    /// Commit the active pane for a tab server-side, rolling the previous active pane
    /// into `lastActivePaneID` (MRU) for `select-pane -l`. Validates membership.
    @discardableResult
    public mutating func setActivePane(workspaceID: WorkspaceID, tabID: TabID, paneID: PaneID) -> Bool {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return false }
        var tab = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex]
        guard tab.rootPane.allPaneIDs().contains(paneID) else { return false }
        if tab.activePaneID == paneID { return true }
        tab.lastActivePaneID = tab.activePaneID
        tab.activePaneID = paneID
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex] = tab
        bumpRevision()
        return true
    }

    /// Resolve a tab's active pane, falling back to the first leaf when unset (older
    /// snapshots / freshly built tabs). Used by target-less commands.
    public func activePaneID(workspaceID: WorkspaceID, tabID: TabID) -> PaneID? {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return nil }
        let tab = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex]
        return tab.activePaneID ?? tab.rootPane.allPaneIDs().first
    }

    /// The active pane of the active tab in the active workspace, if any.
    public func activePaneInActiveTab() -> (workspaceID: WorkspaceID, tabID: TabID, paneID: PaneID)? {
        guard let workspace = snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let pane = tab.activePaneID ?? tab.rootPane.allPaneIDs().first
        else { return nil }
        return (workspace.id, tab.id, pane)
    }

    @discardableResult
    public mutating func selectWorkspace(_ id: WorkspaceID) -> Bool {
        guard snapshot.workspaces.contains(where: { $0.id == id }) else { return false }
        if snapshot.activeWorkspaceID == id { return true }
        snapshot.activeWorkspaceID = id
        bumpRevision()
        return true
    }

    @discardableResult
    public mutating func selectSession(workspaceID: WorkspaceID, sessionID: SessionID) -> Bool {
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }),
              snapshot.workspaces[workspaceIndex].sessions.contains(where: { $0.id == sessionID })
        else { return false }
        if snapshot.workspaces[workspaceIndex].activeSessionID == sessionID { return true }
        snapshot.workspaces[workspaceIndex].activeSessionID = sessionID
        bumpRevision()
        return true
    }

    @discardableResult
    public mutating func selectTab(workspaceID: WorkspaceID, tabID: TabID) -> Bool {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return false }
        // Viewing a tab clears its monitoring alerts.
        let tab = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex]
        let hadAlerts = tab.activity || tab.silence || tab.bell
        if hadAlerts {
            snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].activity = false
            snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].silence = false
            snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].bell = false
        }
        if snapshot.workspaces[match.workspaceIndex].activeSessionID == snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].id,
           snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].activeTabID == tabID
        {
            if hadAlerts { bumpRevision() }
            return true
        }
        snapshot.workspaces[match.workspaceIndex].activeSessionID = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].id
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].activeTabID = tabID
        bumpRevision()
        return true
    }

    /// Move a tab to `toIndex` within its session. `toIndex` is the desired final
    /// position among the reordered tabs (clamped). IDs are unchanged, so the active
    /// tab stays valid.
    @discardableResult
    public mutating func reorderTab(workspaceID: WorkspaceID, tabID: TabID, toIndex: Int) -> Bool {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return false }
        var session = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex]
        guard let from = session.tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let tab = session.tabs.remove(at: from)
        let target = max(0, min(session.tabs.count, toIndex))
        session.tabs.insert(tab, at: target)
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex] = session
        bumpRevision()
        return true
    }

    /// Reassign `sortOrder` to be contiguous (0,1,2,…) in current array order for
    /// every tab in `sessionID` (`renumber-windows`). IDs are unchanged.
    @discardableResult
    public mutating func renumberWindows(sessionID: SessionID) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            guard let sessionIndex = snapshot.workspaces[workspaceIndex].sessions
                .firstIndex(where: { $0.id == sessionID }) else { continue }
            var session = snapshot.workspaces[workspaceIndex].sessions[sessionIndex]
            session.tabs.sort { $0.sortOrder < $1.sortOrder }
            for i in session.tabs.indices { session.tabs[i].sortOrder = i }
            snapshot.workspaces[workspaceIndex].sessions[sessionIndex] = session
            bumpRevision()
            return true
        }
        return false
    }

    /// Swap the tab `tabID` with the tab currently at `withIndex` in the same
    /// session (`swap-window`). IDs are unchanged so both tabs stay valid.
    @discardableResult
    public mutating func swapTab(workspaceID: WorkspaceID, tabID: TabID, withIndex: Int) -> Bool {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return false }
        var session = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex]
        guard let a = session.tabs.firstIndex(where: { $0.id == tabID }),
              withIndex >= 0, withIndex < session.tabs.count, withIndex != a
        else { return false }
        session.tabs.swapAt(a, withIndex)
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex] = session
        bumpRevision()
        return true
    }

    /// Move a session to `toIndex` within its workspace's session list. IDs are
    /// unchanged, so the active session stays valid.
    @discardableResult
    public mutating func reorderSession(workspaceID: WorkspaceID, sessionID: SessionID, toIndex: Int) -> Bool {
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return false }
        var workspace = snapshot.workspaces[workspaceIndex]
        guard let from = workspace.sessions.firstIndex(where: { $0.id == sessionID }) else { return false }
        let session = workspace.sessions.remove(at: from)
        let target = max(0, min(workspace.sessions.count, toIndex))
        workspace.sessions.insert(session, at: target)
        snapshot.workspaces[workspaceIndex] = workspace
        bumpRevision()
        return true
    }

    public mutating func setTheme(_ name: String) {
        guard snapshot.themeName != name else { return }
        snapshot.themeName = name
        bumpRevision()
    }

    public mutating func setKeepSessionsOnQuit(_ value: Bool) {
        guard snapshot.keepSessionsOnQuit != value else { return }
        snapshot.keepSessionsOnQuit = value
        bumpRevision()
    }

    /// Pin/unpin a session so it survives a clean quit even when `keepSessionsOnQuit` is off.
    /// "Promote a normal session to persistent" (and the reverse).
    @discardableResult
    public mutating func setSessionPersistent(_ sessionID: SessionID, _ persistent: Bool) -> Bool {
        for wi in snapshot.workspaces.indices {
            if let si = snapshot.workspaces[wi].sessions.firstIndex(where: { $0.id == sessionID }) {
                guard snapshot.workspaces[wi].sessions[si].persistent != persistent else { return true }
                snapshot.workspaces[wi].sessions[si].persistent = persistent
                bumpRevision()
                return true
            }
        }
        return false
    }

    /// Pin/unpin an individual tab so it survives a clean quit even when neither the global
    /// `keepSessionsOnQuit` nor its session's `persistent` flag is set — the finest-grained
    /// persistence control. Mirrors `setSessionPersistent`.
    @discardableResult
    public mutating func setTabPersistent(_ tabID: TabID, _ persistent: Bool) -> Bool {
        guard let match = tabIndex(tabID: tabID) else { return false }
        guard snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].persistent != persistent
        else { return true }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].persistent = persistent
        bumpRevision()
        return true
    }

    // Persistence precedence on a clean GUI quit (a daemon/GUI crash never reaps — survival
    // across a crash is always a feature):
    //   A tab survives iff `keepSessionsOnQuit || session.persistent || tab.persistent`.
    //   A session is closed iff *none* of its tabs survive.
    // `ephemeralSessionIDs()` returns whole sessions to close; `ephemeralTabIDs()` returns the
    // unpinned tabs to close individually inside sessions that survive only because another tab
    // in them is pinned. The two sets are disjoint by construction.

    /// Sessions to tear down entirely: not globally kept, not session-pinned, and with no
    /// individually-pinned tab to keep them alive.
    public func ephemeralSessionIDs() -> [SessionID] {
        guard !snapshot.keepSessionsOnQuit else { return [] }
        return snapshot.workspaces.flatMap(\.sessions)
            .filter { !$0.persistent && !$0.tabs.contains(where: { $0.persistent }) }
            .map(\.id)
    }

    /// Unpinned tabs to close individually: they live in a session that itself survives only
    /// because a *sibling* tab is pinned (a session-pinned session keeps all its tabs, so it is
    /// skipped here; a session with no pinned tab is closed wholesale via `ephemeralSessionIDs`).
    public func ephemeralTabIDs() -> [TabID] {
        guard !snapshot.keepSessionsOnQuit else { return [] }
        var result: [TabID] = []
        for session in snapshot.workspaces.flatMap(\.sessions) {
            guard !session.persistent, session.tabs.contains(where: { $0.persistent }) else { continue }
            result.append(contentsOf: session.tabs.filter { !$0.persistent }.map(\.id))
        }
        return result
    }

    public mutating func closeTab(_ tabID: TabID) -> Bool {
        guard let match = tabIndex(tabID: tabID) else { return false }
        var session = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex]
        session.tabs.remove(at: match.tabIndex)
        if session.tabs.isEmpty {
            let tab = Tab(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            session.tabs = [tab]
            session.activeTabID = tab.id
        } else if session.activeTabID == tabID {
            let fallbackIndex = min(match.tabIndex, session.tabs.count - 1)
            session.activeTabID = session.tabs[fallbackIndex].id
        }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex] = session
        bumpRevision()
        return true
    }

    /// `link-window`: add a linked copy of `tabID` to `targetSessionID`. The copy
    /// gets fresh pane IDs but **shares the same surface IDs** (live PTYs), so both
    /// tabs show the same content; the daemon ref-counts surfaces so closing one
    /// linked tab keeps the surfaces alive for the other. Returns the new tab ID.
    @discardableResult
    public mutating func linkWindow(_ tabID: TabID, toSessionID targetSessionID: SessionID) -> TabID? {
        guard let match = tabIndex(tabID: tabID) else { return nil }
        let source = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex]
        guard let targetLocation = sessionIndex(sessionID: targetSessionID) else { return nil }

        var linked = source
        linked.id = UUID()
        linked.rootPane = Self.cloneWithFreshPaneIDs(source.rootPane)
        linked.zoomedPaneID = nil
        linked.activePaneID = linked.rootPane.allPaneIDs().first
        linked.lastActivePaneID = nil
        linked.sortOrder = (snapshot.workspaces[targetLocation.workspaceIndex]
            .sessions[targetLocation.sessionIndex].tabs.map(\.sortOrder).max() ?? 0) + 1

        snapshot.workspaces[targetLocation.workspaceIndex].sessions[targetLocation.sessionIndex].tabs.append(linked)
        snapshot.workspaces[targetLocation.workspaceIndex].sessions[targetLocation.sessionIndex].setActiveTab(linked.id)
        bumpRevision()
        return linked.id
    }

    /// `unlink-window`: remove `tabID` only if it is a link (its surfaces are also
    /// referenced by another tab). Returns false if it isn't linked.
    @discardableResult
    public mutating func unlinkWindow(_ tabID: TabID) -> Bool {
        guard let match = tabIndex(tabID: tabID) else { return false }
        let tab = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex]
        let surfaces = Set(tab.rootPane.allSurfaceIDs())
        let sharedElsewhere = snapshot.workspaces
            .flatMap { $0.sessions }.flatMap { $0.tabs }
            .contains { $0.id != tabID && !surfaces.isDisjoint(with: Set($0.rootPane.allSurfaceIDs())) }
        guard sharedElsewhere else { return false }
        return closeTab(tabID)
    }

    // MARK: Grouped sessions (tmux `new-session -t <session>`)

    /// Create an independent session sharing `targetSessionID`'s window list: every
    /// window is a linked copy (fresh tab/pane IDs, SAME surface IDs — live PTYs), and
    /// the new member keeps its own active window. First grouping stamps the group ID
    /// on the target too. Returns the new session's ID.
    public mutating func addGroupedSession(
        groupWith targetSessionID: SessionID,
        name: String? = nil
    ) -> SessionID? {
        guard let loc = sessionIndex(sessionID: targetSessionID) else { return nil }
        let groupID = snapshot.workspaces[loc.workspaceIndex].sessions[loc.sessionIndex].groupID ?? UUID()
        snapshot.workspaces[loc.workspaceIndex].sessions[loc.sessionIndex].groupID = groupID

        let target = snapshot.workspaces[loc.workspaceIndex].sessions[loc.sessionIndex]
        let linkedTabs: [Tab] = target.tabs.map { source in
            var linked = source
            linked.id = UUID()
            linked.rootPane = Self.cloneWithFreshPaneIDs(source.rootPane)
            linked.zoomedPaneID = nil
            linked.activePaneID = linked.rootPane.allPaneIDs().first
            linked.lastActivePaneID = nil
            return linked
        }
        // tmux: the new member starts on the group's CURRENT window (focus then
        // diverges per member) — the linked copy at the target's active position.
        let activeIndex = target.tabs.firstIndex { $0.id == target.activeTabID } ?? 0
        let member = SessionGroup(
            name: name ?? "",
            tabs: linkedTabs,
            activeTabID: (linkedTabs.indices.contains(activeIndex) ? linkedTabs[activeIndex] : linkedTabs.first)?.id,
            sortOrder: (snapshot.workspaces[loc.workspaceIndex].sessions.map(\.sortOrder).max() ?? 0) + 1,
            groupID: groupID
        )
        snapshot.workspaces[loc.workspaceIndex].sessions.append(member)
        snapshot.workspaces[loc.workspaceIndex].activeSessionID = member.id
        bumpRevision()
        return member.id
    }

    /// Group peers of a session (same groupID, excluding itself). Empty when ungrouped.
    func groupPeers(of sessionID: SessionID) -> [(workspaceIndex: Int, sessionIndex: Int)] {
        guard let loc = sessionIndex(sessionID: sessionID),
              let groupID = snapshot.workspaces[loc.workspaceIndex].sessions[loc.sessionIndex].groupID
        else { return [] }
        var peers: [(Int, Int)] = []
        for wsIndex in snapshot.workspaces.indices {
            for sIndex in snapshot.workspaces[wsIndex].sessions.indices
            where snapshot.workspaces[wsIndex].sessions[sIndex].groupID == groupID
                && snapshot.workspaces[wsIndex].sessions[sIndex].id != sessionID {
                peers.append((wsIndex, sIndex))
            }
        }
        return peers
    }

    /// After `addTab` created `tabID` in a grouped session, mirror it into every group
    /// peer as a linked copy (shared surfaces). Peers' active windows are untouched —
    /// tmux: the new window appears in all members, focus changes only where created.
    public mutating func propagateNewTabToGroup(_ tabID: TabID) {
        guard let match = tabIndex(tabID: tabID) else { return }
        let owner = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex]
        let source = owner.tabs[match.tabIndex]
        let peers = groupPeers(of: owner.id) // once — an O(sessions) scan
        for peer in peers {
            var linked = source
            linked.id = UUID()
            linked.rootPane = Self.cloneWithFreshPaneIDs(source.rootPane)
            linked.zoomedPaneID = nil
            linked.activePaneID = linked.rootPane.allPaneIDs().first
            linked.lastActivePaneID = nil
            linked.sortOrder = (snapshot.workspaces[peer.workspaceIndex]
                .sessions[peer.sessionIndex].tabs.map(\.sortOrder).max() ?? 0) + 1
            snapshot.workspaces[peer.workspaceIndex].sessions[peer.sessionIndex].tabs.append(linked)
        }
        if !peers.isEmpty { bumpRevision() }
    }

    /// Before closing `tabID` in a grouped session, find the peer copies of the same
    /// window (tabs sharing any of its live surfaces) so the caller can close them
    /// too — tmux: killing a window removes it from every group member. Overlap, not
    /// set equality: per-window split layouts may diverge between members (a local
    /// split adds a surface to one copy only), and the kill must still propagate —
    /// same sharing predicate as `unlinkWindow`.
    public func groupCounterparts(of tabID: TabID) -> [TabID] {
        guard let match = tabIndex(tabID: tabID) else { return [] }
        let owner = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex]
        let surfaces = Set(owner.tabs[match.tabIndex].rootPane.allSurfaceIDs())
        guard !surfaces.isEmpty else { return [] }
        return groupPeers(of: owner.id).flatMap { peer in
            snapshot.workspaces[peer.workspaceIndex].sessions[peer.sessionIndex].tabs
                .filter { !surfaces.isDisjoint(with: $0.rootPane.allSurfaceIDs()) }
                .map(\.id)
        }
    }

    public mutating func closeSession(_ sessionID: SessionID) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            guard let sessionIndex = snapshot.workspaces[workspaceIndex].sessions.firstIndex(where: { $0.id == sessionID })
            else { continue }
            if snapshot.workspaces[workspaceIndex].sessions.count == 1 {
                let replacement = SessionGroup(sortOrder: 0)
                snapshot.workspaces[workspaceIndex].sessions = [replacement]
                snapshot.workspaces[workspaceIndex].activeSessionID = replacement.id
                bumpRevision()
                return true
            }
            snapshot.workspaces[workspaceIndex].sessions.remove(at: sessionIndex)
            if snapshot.workspaces[workspaceIndex].activeSessionID == sessionID {
                let fallbackIndex = min(sessionIndex, snapshot.workspaces[workspaceIndex].sessions.count - 1)
                snapshot.workspaces[workspaceIndex].activeSessionID = snapshot.workspaces[workspaceIndex].sessions[fallbackIndex].id
            }
            bumpRevision()
            return true
        }
        return false
    }

    public mutating func closeWorkspace(_ id: WorkspaceID) -> Bool {
        guard snapshot.workspaces.count > 1,
              let index = snapshot.workspaces.firstIndex(where: { $0.id == id })
        else { return false }
        snapshot.workspaces.remove(at: index)
        if snapshot.activeWorkspaceID == id {
            snapshot.activeWorkspaceID = snapshot.workspaces.first?.id
        }
        bumpRevision()
        return true
    }

    public mutating func setTabStatus(
        workspaceID: WorkspaceID,
        tabID: TabID,
        status: TabStatus,
        notificationText: String? = nil
    ) {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].status = status
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].notificationText = notificationText
        bumpRevision()
    }

    public mutating func clearTabNotification(surfaceID: SurfaceID) {
        guard let match = tabIndex(surfaceID: surfaceID) else { return }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].status = .idle
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].notificationText = nil
        bumpRevision()
    }

    /// Set monitoring alert flags on a tab (only the provided flags change). Returns whether
    /// anything actually changed, so the daemon commits/fires only on a real transition.
    @discardableResult
    public mutating func setTabAlerts(workspaceID: WorkspaceID, tabID: TabID, activity: Bool? = nil, silence: Bool? = nil, bell: Bool? = nil) -> Bool {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return false }
        var changed = false
        func apply(_ kp: WritableKeyPath<Tab, Bool>, _ value: Bool?) {
            guard let value else { return }
            if snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex][keyPath: kp] != value {
                snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex][keyPath: kp] = value
                changed = true
            }
        }
        apply(\.activity, activity)
        apply(\.silence, silence)
        apply(\.bell, bell)
        if changed { bumpRevision() }
        return changed
    }

    @discardableResult
    public mutating func clearTabAlerts(workspaceID: WorkspaceID, tabID: TabID) -> Bool {
        setTabAlerts(workspaceID: workspaceID, tabID: tabID, activity: false, silence: false, bell: false)
    }

    /// Set/clear a dead pane's exit status (`remain-on-exit`). No-ops (and reports false)
    /// when the value is already current, so revive paths can call it unconditionally
    /// without churning revisions.
    @discardableResult
    public mutating func setTabExitStatus(surfaceID: SurfaceID, status: Int?) -> Bool {
        guard let match = tabIndex(surfaceID: surfaceID),
              snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].exitStatus != status
        else { return false }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].exitStatus = status
        bumpRevision()
        return true
    }

    /// Whether `tabID` is the currently-viewed tab (active tab of the active session in the
    /// active workspace) — output on a viewed tab does not raise an activity alert.
    public func tabIsCurrent(workspaceID: WorkspaceID, tabID: TabID) -> Bool {
        guard snapshot.activeWorkspaceID == workspaceID,
              let ws = snapshot.workspaces.first(where: { $0.id == workspaceID }),
              let sess = ws.sessions.first(where: { $0.tabs.contains { $0.id == tabID } }),
              ws.activeSessionID == sess.id
        else { return false }
        return sess.activeTabID == tabID
    }

    /// Set — or with `nil`, **clear** — the tab's git-branch label (`nil` must clear:
    /// a tab whose directory leaves a repository drops its stale label). Returns whether
    /// the value actually changed (and the revision was bumped), so callers can skip the
    /// commit + subscriber push for an idempotent re-send.
    @discardableResult
    public mutating func setTabGitBranch(
        workspaceID: WorkspaceID,
        tabID: TabID,
        branch: String?
    ) -> Bool {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID),
              snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex]
                  .tabs[match.tabIndex].gitBranch != branch
        else { return false }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex]
            .tabs[match.tabIndex].gitBranch = branch
        bumpRevision()
        return true
    }

    public mutating func updateTabTitle(surfaceID: SurfaceID, title: String) {
        guard let match = tabIndex(surfaceID: surfaceID) else { return }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].title = title
        bumpRevision()
    }

    public mutating func updateTabCwd(surfaceID: SurfaceID, path: String) {
        guard let match = tabIndex(surfaceID: surfaceID) else { return }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].cwd = path
        bumpRevision()
    }

    /// Foreground-command metadata (`#{pane_current_command}`), refreshed by the daemon's
    /// metadata scan alongside cwd — same per-tab granularity as `updateTabCwd`.
    public mutating func updateTabCurrentCommand(surfaceID: SurfaceID, command: String?) {
        guard let match = tabIndex(surfaceID: surfaceID) else { return }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].currentCommand = command
        bumpRevision()
    }

    public func tab(for surfaceID: SurfaceID) -> (workspaceID: WorkspaceID, tabID: TabID)? {
        tab(forSurfaceKey: surfaceID.uuidString)
    }

    public func tab(forSurfaceKey key: String) -> (workspaceID: WorkspaceID, tabID: TabID)? {
        guard let match = tabIndex(surfaceKey: key) else { return nil }
        return (
            snapshot.workspaces[match.workspaceIndex].id,
            snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].id
        )
    }

    /// Tab + pane backing a surface key, plus how many panes the tab has. Used by
    /// `remain-on-exit off`: close just the dead pane, or the whole tab when it was the last.
    public func paneLocation(forSurfaceKey key: String) -> (tabID: TabID, paneID: PaneID, paneCount: Int)? {
        func leaf(_ node: PaneNode) -> PaneLeaf? {
            switch node {
            case let .leaf(l): return l.surfaceID.uuidString == key ? l : nil
            case let .branch(_, _, first, second): return leaf(first) ?? leaf(second)
            }
        }
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if let l = leaf(tab.rootPane) {
                        return (tab.id, l.id, tab.rootPane.allPaneIDs().count)
                    }
                }
            }
        }
        return nil
    }

    public func surfaceID(forPaneID paneID: PaneID) -> SurfaceID? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if let surfaceID = surfaceID(forPaneID: paneID, in: tab.rootPane) {
                        return surfaceID
                    }
                }
            }
        }
        return nil
    }

    /// The workspace + tab that contains `paneID`, if any.
    public func tab(containingPaneID paneID: PaneID) -> (workspaceID: WorkspaceID, tabID: TabID)? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.rootPane.allPaneIDs().contains(paneID) {
                    return (workspace.id, tab.id)
                }
            }
        }
        return nil
    }

    public func firstWaitingTab() -> (workspaceID: WorkspaceID, tabID: TabID)? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.status == .waiting {
                    return (workspace.id, tab.id)
                }
            }
        }
        return nil
    }

    public mutating func renameTab(_ tabID: TabID, name: String) -> Bool {
        guard let match = tabIndex(tabID: tabID) else { return false }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].title = name
        bumpRevision()
        return true
    }

    public mutating func renameSession(_ sessionID: SessionID, name: String) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            guard let sessionIndex = snapshot.workspaces[workspaceIndex].sessions.firstIndex(where: { $0.id == sessionID }) else {
                continue
            }
            snapshot.workspaces[workspaceIndex].sessions[sessionIndex].name = name
            bumpRevision()
            return true
        }
        return false
    }

    public mutating func renameWorkspace(_ id: WorkspaceID, name: String) -> Bool {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == id }) else { return false }
        snapshot.workspaces[index].name = name
        bumpRevision()
        return true
    }

    public mutating func killPane(_ paneID: PaneID) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    if tab.rootPane.allPaneIDs().contains(paneID), removePane(&tab.rootPane, target: paneID) {
                        if tab.zoomedPaneID == paneID { tab.zoomedPaneID = nil }
                        repairActivePane(&tab, removed: paneID)
                        snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                        bumpRevision()
                        return true
                    }
                }
            }
        }
        return false
    }

    public mutating func swapPanes(_ srcID: PaneID, _ dstID: PaneID) -> Bool {
        var srcLeaf: PaneLeaf?
        var dstLeaf: PaneLeaf?
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if let leaf = leaf(in: tab.rootPane, paneID: srcID) { srcLeaf = leaf }
                    if let leaf = leaf(in: tab.rootPane, paneID: dstID) { dstLeaf = leaf }
                }
            }
        }
        guard let src = srcLeaf, let dst = dstLeaf else { return false }
        // Swap in a SINGLE traversal that decides per leaf. Two sequential id-keyed
        // replaceLeaf passes corrupt the tree: the first pass turns src's slot into a
        // copy of dst (now carrying dst.id), so the second pass matches BOTH dst-id
        // leaves and overwrites them, destroying one pane and duplicating the other.
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    swapLeaves(in: &tab.rootPane, srcID: src.id, src: src, dstID: dst.id, dst: dst)
                    snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                }
            }
        }
        bumpRevision()
        return true
    }

    public mutating func zoomPane(_ paneID: PaneID) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    guard tab.rootPane.allPaneIDs().contains(paneID) else { continue }
                    tab.zoomedPaneID = (tab.zoomedPaneID == paneID) ? nil : paneID
                    snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                    bumpRevision()
                    return true
                }
            }
        }
        return false
    }

    public mutating func resizePane(_ paneID: PaneID, direction: ResizeDirection, amount: Int) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    guard tab.rootPane.allPaneIDs().contains(paneID) else { continue }
                    let delta = CGFloat(amount) * 0.05
                    let signed: CGFloat
                    switch direction {
                    case .left, .up: signed = -delta
                    case .right, .down: signed = delta
                    }
                    _ = adjustRatio(&tab.rootPane, target: paneID, delta: signed)
                    snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                    bumpRevision()
                    return true
                }
            }
        }
        return false
    }

    /// Set the absolute split ratio of the branch identified by the representative
    /// (first) leaf of each child subtree. That pair is unambiguous even when splits
    /// are nested (ancestor branches share a first-leaf but not the pair).
    @discardableResult
    public mutating func setSplitRatio(
        tabID: TabID,
        firstPaneID: PaneID,
        secondPaneID: PaneID,
        ratio: Double
    ) -> Bool {
        guard let match = tabIndex(tabID: tabID) else { return false }
        var tab = snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex]
        let clamped = min(0.9, max(0.1, ratio))
        guard setRatio(&tab.rootPane, firstPaneID: firstPaneID, secondPaneID: secondPaneID, ratio: clamped) else {
            return false
        }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex] = tab
        bumpRevision()
        return true
    }

    public mutating func setAgent(_ agent: AgentSnapshot?, forSurfaceKey key: String) {
        guard let match = tabIndex(surfaceKey: key) else { return }
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].agent = agent
        bumpRevision()
    }

    public func listSurfaces() -> [SurfaceSummary] {
        var result: [SurfaceSummary] = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    for surfaceID in tab.rootPane.allSurfaceIDs() {
                        result.append(SurfaceSummary(
                            surfaceID: surfaceID.uuidString,
                            tabTitle: tab.title,
                            workspaceName: workspace.name,
                            cwd: tab.cwd
                        ))
                    }
                }
            }
        }
        return result
    }

    /// One row per running agent — a flattened view of every tab carrying a
    /// detected agent (`Tab.agent`), with its workspace/session/tab/pane context,
    /// state, and the `.waiting` "needs you" signal. When process-tree detection
    /// cannot see an agent but the tab title clearly names one, use the same title
    /// fallback as the GUI tab strip so wrapped/renamed agent processes still appear.
    /// Mirrors `listSurfaces()`.
    /// The surface/pane reported is the tab's active pane (falling back to its
    /// first leaf), i.e. the one a caller would address.
    public func listAgents() -> [AgentSessionSummary] {
        var result: [AgentSessionSummary] = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    let agent: AgentSnapshot
                    if let detected = tab.agent {
                        agent = detected
                    } else if let inferredKind = AgentTitleInference.kind(from: tab.title) {
                        agent = AgentSnapshot(
                            kind: inferredKind,
                            executable: "",
                            pid: 0,
                            activity: tab.status == .waiting ? .awaiting : .idle,
                            lastActivityAt: snapshot.savedAt
                        )
                    } else {
                        continue
                    }
                    let leaves = tab.rootPane.allLeaves()
                    let activeLeaf = tab.activePaneID.flatMap { active in leaves.first { $0.id == active } }
                    let leaf = activeLeaf ?? leaves.first
                    result.append(AgentSessionSummary(
                        workspaceName: workspace.name,
                        sessionID: session.id,
                        sessionName: session.name,
                        tabID: tab.id,
                        tabTitle: tab.title,
                        surfaceID: leaf?.surfaceID.uuidString ?? "",
                        paneID: leaf?.id.uuidString,
                        kind: agent.kind,
                        activity: agent.activity,
                        waiting: tab.status == .waiting,
                        lastActivityAt: agent.lastActivityAt,
                        notificationText: tab.notificationText
                    ))
                }
            }
        }
        return result
    }

    private func tabIndex(workspaceID: WorkspaceID, tabID: TabID) -> (workspaceIndex: Int, sessionIndex: Int, tabIndex: Int)? {
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
            if let tabIndex = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.firstIndex(where: { $0.id == tabID }) {
                return (workspaceIndex, sessionIndex, tabIndex)
            }
        }
        return nil
    }

    private func tabIndex(tabID: TabID) -> (workspaceIndex: Int, sessionIndex: Int, tabIndex: Int)? {
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                if let tabIndex = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.firstIndex(where: { $0.id == tabID }) {
                    return (workspaceIndex, sessionIndex, tabIndex)
                }
            }
        }
        return nil
    }

    private func sessionIndex(sessionID: SessionID) -> (workspaceIndex: Int, sessionIndex: Int)? {
        for workspaceIndex in snapshot.workspaces.indices {
            if let sessionIndex = snapshot.workspaces[workspaceIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
                return (workspaceIndex, sessionIndex)
            }
        }
        return nil
    }

    private func tabIndex(surfaceID: SurfaceID) -> (workspaceIndex: Int, sessionIndex: Int, tabIndex: Int)? {
        tabIndex(surfaceKey: surfaceID.uuidString)
    }

    private func tabIndex(surfaceKey: String) -> (workspaceIndex: Int, sessionIndex: Int, tabIndex: Int)? {
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    let tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    if tab.rootPane.allSurfaceIDs().contains(where: { $0.uuidString == surfaceKey }) {
                        return (workspaceIndex, sessionIndex, tabIndex)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Phase 4: directional select, layouts, break/join/rotate

    /// Resolve the directional neighbor of `paneID` within its tab. The
    /// algorithm walks up the binary tree to find the first ancestor whose
    /// split axis matches `direction` and from whose opposite child we came;
    /// then descends back into the other subtree to the leaf nearest the
    /// shared edge. Returns `nil` when no neighbor exists (e.g. the active
    /// pane is already at the requested edge).
    public func directionalNeighbor(of paneID: PaneID, direction: Command.PaneTarget) -> PaneID? {
        guard direction == .left || direction == .right || direction == .up || direction == .down else {
            return nil
        }
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if let path = pathTo(paneID: paneID, in: tab.rootPane) {
                        return findNeighbor(in: tab.rootPane, path: path, direction: direction)
                    }
                }
            }
        }
        return nil
    }

    /// Apply a named layout to the panes in `tabID`. The active pane (if known
    /// via `mainPaneID`) is preserved as the "main" pane for layouts that have
    /// one (main-vertical / main-horizontal). Surfaces are reused; only the
    /// tree structure + ratios are rebuilt.
    public mutating func applyLayout(
        tabID: TabID,
        layout: LayoutTemplate,
        mainPaneID: PaneID? = nil
    ) -> Bool {
        guard let index = tabIndex(tabID: tabID) else { return false }
        var tab = snapshot.workspaces[index.workspaceIndex].sessions[index.sessionIndex].tabs[index.tabIndex]
        let leaves = collectLeaves(in: tab.rootPane)
        guard leaves.count >= 2 else { return false }
        let ordered: [PaneLeaf]
        if let main = mainPaneID, let main = leaves.first(where: { $0.id == main }) {
            ordered = [main] + leaves.filter { $0.id != main.id }
        } else {
            ordered = leaves
        }
        tab.rootPane = build(layout: layout, leaves: ordered)
        tab.zoomedPaneID = nil
        snapshot.workspaces[index.workspaceIndex].sessions[index.sessionIndex].tabs[index.tabIndex] = tab
        bumpRevision()
        return true
    }

    /// Cycle children at each branch (the `rotate-window` command).
    public mutating func rotatePanes(tabID: TabID, forward: Bool) -> Bool {
        guard let index = tabIndex(tabID: tabID) else { return false }
        var tab = snapshot.workspaces[index.workspaceIndex].sessions[index.sessionIndex].tabs[index.tabIndex]
        let leaves = collectLeaves(in: tab.rootPane)
        guard leaves.count >= 2 else { return false }
        let rotated: [PaneLeaf]
        if forward {
            rotated = Array(leaves.dropFirst()) + [leaves.first!]
        } else {
            rotated = [leaves.last!] + Array(leaves.dropLast())
        }
        // Re-emit a balanced tree with the same SplitDirection mix as the
        // original by walking the original's structure and substituting.
        var iterator = rotated.makeIterator()
        tab.rootPane = substituteLeaves(in: tab.rootPane, iterator: &iterator)
        snapshot.workspaces[index.workspaceIndex].sessions[index.sessionIndex].tabs[index.tabIndex] = tab
        bumpRevision()
        return true
    }

    /// Extract `paneID` from its tab and place it as the root of a brand-new
    /// tab in the same session. Returns the new TabID. Surface keeps its
    /// daemon-side PTY (no respawn).
    public mutating func breakPane(paneID: PaneID) -> TabID? {
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    guard let leaf = leaf(in: tab.rootPane, paneID: paneID) else { continue }
                    // Don't break the last pane in a tab — that would just close it.
                    guard tab.rootPane.allPaneIDs().count > 1 else { return nil }
                    _ = removePane(&tab.rootPane, target: paneID)
                    if tab.zoomedPaneID == paneID { tab.zoomedPaneID = nil }
                    repairActivePane(&tab, removed: paneID)
                    snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                    // New tab's Tab.init defaults activePaneID to its only leaf.
                    let newTab = Tab(cwd: tab.cwd, rootPane: .leaf(leaf))
                    snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.append(newTab)
                    bumpRevision()
                    return newTab.id
                }
            }
        }
        return nil
    }

    /// Move `sourcePaneID` from its current tab into `destPaneID`'s tab,
    /// splitting `destPaneID`'s position with `direction`. Surfaces are
    /// preserved.
    @discardableResult
    public mutating func joinPane(
        sourcePaneID: PaneID,
        destPaneID: PaneID,
        direction: SplitDirection
    ) -> PaneID? {
        // Validate BOTH ends before mutating (the swapPanes pattern). The removal below writes
        // into `snapshot` immediately, so failing the destination lookup afterwards would leave
        // the source pane silently dropped from its tab — corruption that every read serves and
        // the next unrelated commit persists. CLI/IPC pass arbitrary --src/--dst UUIDs here.
        guard sourcePaneID != destPaneID else { return nil }
        var destinationExists = false
        var sourceJoinable = false
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if leaf(in: tab.rootPane, paneID: destPaneID) != nil { destinationExists = true }
                    if leaf(in: tab.rootPane, paneID: sourcePaneID) != nil {
                        // A lone pane can't be joined away — it would orphan an empty tab.
                        sourceJoinable = tab.rootPane.allPaneIDs().count > 1
                    }
                }
            }
        }
        guard destinationExists, sourceJoinable else { return nil }
        var sourceLeaf: PaneLeaf?
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    if let leaf = leaf(in: tab.rootPane, paneID: sourcePaneID) {
                        sourceLeaf = leaf
                        if tab.rootPane.allPaneIDs().count > 1 {
                            _ = removePane(&tab.rootPane, target: sourcePaneID)
                            if tab.zoomedPaneID == sourcePaneID { tab.zoomedPaneID = nil }
                            repairActivePane(&tab, removed: sourcePaneID)
                            snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                        } else {
                            // Source pane is the only one in its tab — joining
                            // would orphan an empty tab. Refuse.
                            return nil
                        }
                    }
                }
            }
        }
        guard let leaf = sourceLeaf else { return nil }
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    guard tab.rootPane.allPaneIDs().contains(destPaneID) else { continue }
                    let newLeaf = PaneLeaf(id: UUID(), surfaceID: leaf.surfaceID, daemonSurfaceID: leaf.daemonSurfaceID)
                    insertSplit(&tab.rootPane, at: destPaneID, with: newLeaf, direction: direction)
                    // Focus follows the joined pane into the destination tab.
                    tab.lastActivePaneID = tab.activePaneID
                    tab.activePaneID = newLeaf.id
                    snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                    bumpRevision()
                    return newLeaf.id
                }
            }
        }
        return nil
    }

    // MARK: - Phase 4 internals

    private func existingWorkingDirectory(_ raw: String?) -> String {
        let fallback = FileManager.default.homeDirectoryForCurrentUser.path
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return expanded
        }
        var candidate = (expanded as NSString).deletingLastPathComponent
        while !candidate.isEmpty {
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { break }
            candidate = parent
        }
        return fallback
    }
}
