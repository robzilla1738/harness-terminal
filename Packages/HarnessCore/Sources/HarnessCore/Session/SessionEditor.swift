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
        snapshot.workspaces[match.workspaceIndex].sessions[match.sessionIndex].tabs[match.tabIndex] = tab
        bumpRevision()
        return newPaneID
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
                        snapshot.workspaces[workspaceIndex].sessions[sessionIndex].tabs[tabIndex] = tab
                        bumpRevision()
                        return true
                    }
                }
            }
        }
        return false
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
