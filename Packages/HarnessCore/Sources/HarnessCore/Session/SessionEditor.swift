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

    private func split(node: inout PaneNode, targetPaneID: PaneID, direction: SplitDirection) -> PaneID? {
        switch node {
        case let .leaf(leaf) where leaf.id == targetPaneID:
            let newLeaf = PaneLeaf()
            node = .branch(direction: direction, ratio: 0.5, first: .leaf(leaf), second: .leaf(newLeaf))
            return newLeaf.id
        case .branch(let existingDirection, let ratio, var first, var second):
            if let id = split(node: &first, targetPaneID: targetPaneID, direction: direction) {
                node = .branch(direction: existingDirection, ratio: ratio, first: first, second: second)
                return id
            }
            if let id = split(node: &second, targetPaneID: targetPaneID, direction: direction) {
                node = .branch(direction: existingDirection, ratio: ratio, first: first, second: second)
                return id
            }
            return nil
        default:
            return nil
        }
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
        if snapshot.workspaces[match.workspaceIndex].activeSessionID == snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].id,
           snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].activeTabID == tabID
        {
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

    /// Clone a pane tree keeping surface IDs but assigning fresh pane IDs.
    static func cloneWithFreshPaneIDs(_ node: PaneNode) -> PaneNode {
        switch node {
        case let .leaf(leaf):
            return .leaf(PaneLeaf(id: UUID(), surfaceID: leaf.surfaceID, daemonSurfaceID: leaf.daemonSurfaceID))
        case let .branch(direction, ratio, first, second):
            return .branch(direction: direction, ratio: ratio,
                           first: cloneWithFreshPaneIDs(first), second: cloneWithFreshPaneIDs(second))
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

    public mutating func updateTabMetadata(
        workspaceID: WorkspaceID,
        tabID: TabID,
        gitBranch: String?,
        cwd: String?
    ) {
        guard let match = tabIndex(workspaceID: workspaceID, tabID: tabID) else { return }
        if let gitBranch {
            snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].gitBranch = gitBranch
        }
        if let cwd {
            snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex].cwd = cwd
        }
        bumpRevision()
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

    private func surfaceID(forPaneID paneID: PaneID, in node: PaneNode) -> SurfaceID? {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID:
            return leaf.surfaceID
        case let .branch(_, _, first, second):
            return surfaceID(forPaneID: paneID, in: first) ?? surfaceID(forPaneID: paneID, in: second)
        default:
            return nil
        }
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

    /// After a pane leaves a tab (kill / break / join-source), ensure the tab still
    /// has a valid focus: keep the current active pane if it survived, else promote
    /// the MRU pane, else the first remaining leaf.
    private func repairActivePane(_ tab: inout Tab, removed paneID: PaneID) {
        let remaining = tab.rootPane.allPaneIDs()
        if let last = tab.lastActivePaneID, last == paneID || !remaining.contains(last) {
            tab.lastActivePaneID = nil
        }
        if let active = tab.activePaneID, active != paneID, remaining.contains(active) { return }
        tab.activePaneID = tab.lastActivePaneID ?? remaining.first
        tab.lastActivePaneID = nil
    }

    private func removePane(_ node: inout PaneNode, target: PaneID) -> Bool {
        switch node {
        case let .leaf(leaf) where leaf.id == target:
            return false
        case .branch(let direction, let ratio, var first, var second):
            if case let .leaf(leaf) = first, leaf.id == target {
                node = second
                return true
            }
            if case let .leaf(leaf) = second, leaf.id == target {
                node = first
                return true
            }
            if removePane(&first, target: target) {
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            if removePane(&second, target: target) {
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            return false
        default:
            return false
        }
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
        for workspaceIndex in snapshot.workspaces.indices {
            for sessionIndex in snapshot.workspaces[workspaceIndex].sessions.indices {
                for tabIndex in snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs.indices {
                    var tab = snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex]
                    replaceLeaf(in: &tab.rootPane, paneID: src.id, with: dst)
                    replaceLeaf(in: &tab.rootPane, paneID: dst.id, with: src)
                    snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                }
            }
        }
        bumpRevision()
        return true
    }

    private func leaf(in node: PaneNode, paneID: PaneID) -> PaneLeaf? {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID: return leaf
        case let .branch(_, _, first, second): return leaf(in: first, paneID: paneID) ?? leaf(in: second, paneID: paneID)
        default: return nil
        }
    }

    private func replaceLeaf(in node: inout PaneNode, paneID: PaneID, with replacement: PaneLeaf) {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID:
            node = .leaf(replacement)
        case .branch(let direction, let ratio, var first, var second):
            replaceLeaf(in: &first, paneID: paneID, with: replacement)
            replaceLeaf(in: &second, paneID: paneID, with: replacement)
            node = .branch(direction: direction, ratio: ratio, first: first, second: second)
        default:
            break
        }
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

    @discardableResult
    private func adjustRatio(_ node: inout PaneNode, target: PaneID, delta: CGFloat) -> Bool {
        switch node {
        case let .leaf(leaf) where leaf.id == target:
            return true
        case .branch(let direction, var ratio, var first, var second):
            if adjustRatio(&first, target: target, delta: delta) {
                ratio = min(0.9, max(0.1, ratio + delta))
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            if adjustRatio(&second, target: target, delta: delta) {
                ratio = min(0.9, max(0.1, ratio - delta))
                node = .branch(direction: direction, ratio: ratio, first: first, second: second)
                return true
            }
            return false
        default:
            return false
        }
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

    private func setRatio(_ node: inout PaneNode, firstPaneID: PaneID, secondPaneID: PaneID, ratio: Double) -> Bool {
        guard case .branch(let direction, let existingRatio, var first, var second) = node else { return false }
        if firstLeafID(in: first) == firstPaneID, firstLeafID(in: second) == secondPaneID {
            node = .branch(direction: direction, ratio: ratio, first: first, second: second)
            return true
        }
        if setRatio(&first, firstPaneID: firstPaneID, secondPaneID: secondPaneID, ratio: ratio) {
            node = .branch(direction: direction, ratio: existingRatio, first: first, second: second)
            return true
        }
        if setRatio(&second, firstPaneID: firstPaneID, secondPaneID: secondPaneID, ratio: ratio) {
            node = .branch(direction: direction, ratio: existingRatio, first: first, second: second)
            return true
        }
        return false
    }

    private func firstLeafID(in node: PaneNode) -> PaneID? {
        switch node {
        case let .leaf(leaf): return leaf.id
        case let .branch(_, _, first, _): return firstLeafID(in: first)
        }
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

    private func pathTo(paneID: PaneID, in node: PaneNode) -> [Int]? {
        switch node {
        case let .leaf(leaf): return leaf.id == paneID ? [] : nil
        case let .branch(_, _, first, second):
            if let sub = pathTo(paneID: paneID, in: first) { return [0] + sub }
            if let sub = pathTo(paneID: paneID, in: second) { return [1] + sub }
            return nil
        }
    }

    private func findNeighbor(in root: PaneNode, path: [Int], direction: Command.PaneTarget) -> PaneID? {
        // Walk up until we find a branch whose split axis matches `direction`
        // and we descended from the side opposite the direction we want.
        var cursor = root
        var ancestors: [(direction: SplitDirection, came: Int)] = []
        for step in path {
            if case let .branch(direction, _, first, second) = cursor {
                ancestors.append((direction, step))
                cursor = step == 0 ? first : second
            } else {
                return nil
            }
        }
        guard case .leaf = cursor else { return nil }
        // Decide which axis matches the request.
        let wantHorizontalAxis: Bool = direction == .left || direction == .right
        let wantNegativeSide: Bool = direction == .left || direction == .up
        for i in (0..<ancestors.count).reversed() {
            let ancestor = ancestors[i]
            let isHorizontal = ancestor.direction == .vertical // .vertical divider → side-by-side
            if isHorizontal == wantHorizontalAxis {
                // We need to have come from the side opposite the target side.
                let cameFromHigh = ancestor.came == 1
                if (wantNegativeSide && cameFromHigh) || (!wantNegativeSide && !cameFromHigh) {
                    // Descend the OTHER side, picking the leaf closest to the
                    // shared edge: rightmost when going left, leftmost when going
                    // right, bottommost when going up, topmost when going down.
                    var descend = root
                    for step in path.prefix(i) {
                        guard case let .branch(_, _, first, second) = descend else { return nil }
                        descend = step == 0 ? first : second
                    }
                    guard case let .branch(_, _, first, second) = descend else { return nil }
                    descend = wantNegativeSide ? first : second
                    while case let .branch(branchDir, _, l, r) = descend {
                        if branchDir == ancestor.direction {
                            // Same axis — pick the leaf adjacent to the shared edge.
                            descend = wantNegativeSide ? r : l
                        } else {
                            // Different axis — descend into either side; pick
                            // the first leaf to keep behavior deterministic.
                            descend = l
                        }
                    }
                    return descend.paneID
                }
            }
        }
        return nil
    }

    private func collectLeaves(in node: PaneNode) -> [PaneLeaf] {
        switch node {
        case let .leaf(leaf): return [leaf]
        case let .branch(_, _, first, second):
            return collectLeaves(in: first) + collectLeaves(in: second)
        }
    }

    private func substituteLeaves(in node: PaneNode, iterator: inout IndexingIterator<[PaneLeaf]>) -> PaneNode {
        switch node {
        case .leaf:
            return iterator.next().map { .leaf($0) } ?? node
        case let .branch(direction, ratio, first, second):
            let f = substituteLeaves(in: first, iterator: &iterator)
            let s = substituteLeaves(in: second, iterator: &iterator)
            return .branch(direction: direction, ratio: ratio, first: f, second: s)
        }
    }

    private func insertSplit(_ node: inout PaneNode, at target: PaneID, with newLeaf: PaneLeaf, direction: SplitDirection) {
        switch node {
        case let .leaf(leaf) where leaf.id == target:
            node = .branch(direction: direction, ratio: 0.5, first: .leaf(leaf), second: .leaf(newLeaf))
        case .branch(let dir, let ratio, var first, var second):
            insertSplit(&first, at: target, with: newLeaf, direction: direction)
            insertSplit(&second, at: target, with: newLeaf, direction: direction)
            node = .branch(direction: dir, ratio: ratio, first: first, second: second)
        default:
            break
        }
    }

    private func build(layout: LayoutTemplate, leaves: [PaneLeaf]) -> PaneNode {
        switch layout {
        case .evenHorizontal:
            // panes side-by-side (vertical dividers between them)
            return buildEven(leaves: leaves, direction: .vertical)
        case .evenVertical:
            return buildEven(leaves: leaves, direction: .horizontal)
        case .mainHorizontal:
            // main pane on top (full width), the rest tiled side-by-side underneath
            guard let main = leaves.first else { return .leaf(PaneLeaf()) }
            let rest = Array(leaves.dropFirst())
            if rest.isEmpty { return .leaf(main) }
            let bottom = buildEven(leaves: rest, direction: .vertical)
            return .branch(direction: .horizontal, ratio: 0.5, first: .leaf(main), second: bottom)
        case .mainVertical:
            // main pane on left (full height), rest stacked top/bottom on right
            guard let main = leaves.first else { return .leaf(PaneLeaf()) }
            let rest = Array(leaves.dropFirst())
            if rest.isEmpty { return .leaf(main) }
            let right = buildEven(leaves: rest, direction: .horizontal)
            return .branch(direction: .vertical, ratio: 0.5, first: .leaf(main), second: right)
        case .tiled:
            return buildTiled(leaves: leaves)
        }
    }

    private func buildEven(leaves: [PaneLeaf], direction: SplitDirection) -> PaneNode {
        guard !leaves.isEmpty else { return .leaf(PaneLeaf()) }
        if leaves.count == 1 { return .leaf(leaves[0]) }
        // Recursive equal split — produces a balanced binary tree whose visual
        // result is N evenly-sized panes along the chosen axis.
        let mid = leaves.count / 2
        let left = Array(leaves.prefix(mid))
        let right = Array(leaves.suffix(from: mid))
        let ratio = Double(left.count) / Double(leaves.count)
        return .branch(
            direction: direction,
            ratio: ratio,
            first: buildEven(leaves: left, direction: direction),
            second: buildEven(leaves: right, direction: direction)
        )
    }

    private func buildTiled(leaves: [PaneLeaf]) -> PaneNode {
        // Grid that's roughly square. For N leaves, columns = ceil(sqrt(N)),
        // rows = ceil(N / columns). Last row may be shorter.
        guard !leaves.isEmpty else { return .leaf(PaneLeaf()) }
        if leaves.count == 1 { return .leaf(leaves[0]) }
        let columns = max(1, Int(Double(leaves.count).squareRoot().rounded(.up)))
        var rows: [[PaneLeaf]] = []
        var i = 0
        while i < leaves.count {
            let end = min(i + columns, leaves.count)
            rows.append(Array(leaves[i..<end]))
            i = end
        }
        let rowNodes = rows.map { buildEven(leaves: $0, direction: .vertical) }
        return buildEvenNodes(rowNodes, direction: .horizontal)
    }

    private func buildEvenNodes(_ nodes: [PaneNode], direction: SplitDirection) -> PaneNode {
        guard !nodes.isEmpty else { return .leaf(PaneLeaf()) }
        if nodes.count == 1 { return nodes[0] }
        let mid = nodes.count / 2
        let left = Array(nodes.prefix(mid))
        let right = Array(nodes.suffix(from: mid))
        let ratio = Double(left.count) / Double(nodes.count)
        return .branch(
            direction: direction,
            ratio: ratio,
            first: buildEvenNodes(left, direction: direction),
            second: buildEvenNodes(right, direction: direction)
        )
    }

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
