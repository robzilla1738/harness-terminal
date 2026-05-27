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

    public mutating func addTab(to workspaceID: WorkspaceID, cwd: String? = nil) -> TabID? {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return nil
        }
        let tab = Tab(
            cwd: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            sortOrder: snapshot.workspaces[index].tabs.count
        )
        snapshot.workspaces[index].tabs.append(tab)
        snapshot.workspaces[index].activeTabID = tab.id
        bumpRevision()
        return tab.id
    }

    public mutating func splitPane(
        in workspaceID: WorkspaceID,
        tabID: TabID,
        paneID: PaneID,
        direction: SplitDirection
    ) -> PaneID? {
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID })
        else { return nil }

        var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
        guard let newPaneID = split(node: &tab.rootPane, targetPaneID: paneID, direction: direction) else {
            return nil
        }
        snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
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

    public mutating func selectWorkspace(_ id: WorkspaceID) {
        snapshot.activeWorkspaceID = id
        bumpRevision()
    }

    public mutating func selectTab(workspaceID: WorkspaceID, tabID: TabID) {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        snapshot.workspaces[index].activeTabID = tabID
        bumpRevision()
    }

    public mutating func closeTab(_ tabID: TabID) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            guard let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID })
            else { continue }
            snapshot.workspaces[workspaceIndex].tabs.remove(at: tabIndex)
            if snapshot.workspaces[workspaceIndex].activeTabID == tabID {
                snapshot.workspaces[workspaceIndex].activeTabID = snapshot.workspaces[workspaceIndex].tabs.first?.id
            }
            if snapshot.workspaces[workspaceIndex].tabs.isEmpty {
                let tab = Tab(cwd: FileManager.default.homeDirectoryForCurrentUser.path)
                snapshot.workspaces[workspaceIndex].tabs = [tab]
                snapshot.workspaces[workspaceIndex].activeTabID = tab.id
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
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        snapshot.workspaces[workspaceIndex].tabs[tabIndex].status = status
        if let notificationText {
            snapshot.workspaces[workspaceIndex].tabs[tabIndex].notificationText = notificationText
        }
        bumpRevision()
    }

    public mutating func clearTabNotification(surfaceID: SurfaceID) {
        guard let match = tab(for: surfaceID) else { return }
        setTabStatus(
            workspaceID: match.workspaceID,
            tabID: match.tabID,
            status: .idle,
            notificationText: nil
        )
        if let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == match.workspaceID }),
           let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == match.tabID })
        {
            snapshot.workspaces[workspaceIndex].tabs[tabIndex].notificationText = nil
        }
    }

    public mutating func updateTabMetadata(
        workspaceID: WorkspaceID,
        tabID: TabID,
        gitBranch: String?,
        cwd: String?
    ) {
        guard let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID })
        else { return }
        if let gitBranch {
            snapshot.workspaces[workspaceIndex].tabs[tabIndex].gitBranch = gitBranch
        }
        if let cwd {
            snapshot.workspaces[workspaceIndex].tabs[tabIndex].cwd = cwd
        }
        bumpRevision()
    }

    public mutating func updateTabTitle(surfaceID: SurfaceID, title: String) {
        guard let match = tab(for: surfaceID),
              let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == match.workspaceID }),
              let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == match.tabID })
        else { return }
        snapshot.workspaces[workspaceIndex].tabs[tabIndex].title = title
        bumpRevision()
    }

    public mutating func updateTabCwd(surfaceID: SurfaceID, path: String) {
        guard let match = tab(for: surfaceID),
              let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == match.workspaceID }),
              let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == match.tabID })
        else { return }
        snapshot.workspaces[workspaceIndex].tabs[tabIndex].cwd = path
        bumpRevision()
    }

    public func tab(for surfaceID: SurfaceID) -> (workspaceID: WorkspaceID, tabID: TabID)? {
        tab(forSurfaceKey: surfaceID.uuidString)
    }

    public func tab(forSurfaceKey key: String) -> (workspaceID: WorkspaceID, tabID: TabID)? {
        for workspace in snapshot.workspaces {
            for tab in workspace.tabs {
                if tab.rootPane.allSurfaceIDs().contains(where: { $0.uuidString == key }) {
                    return (workspace.id, tab.id)
                }
            }
        }
        return nil
    }

    public func surfaceID(forPaneID paneID: PaneID) -> SurfaceID? {
        for workspace in snapshot.workspaces {
            for tab in workspace.tabs {
                if let surfaceID = surfaceID(forPaneID: paneID, in: tab.rootPane) {
                    return surfaceID
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
            for tab in workspace.tabs where tab.status == .waiting {
                return (workspace.id, tab.id)
            }
        }
        return nil
    }

    public mutating func renameTab(_ tabID: TabID, name: String) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            if let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == tabID }) {
                snapshot.workspaces[workspaceIndex].tabs[tabIndex].title = name
                bumpRevision()
                return true
            }
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
            for tabIndex in snapshot.workspaces[workspaceIndex].tabs.indices {
                var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
                if tab.rootPane.allPaneIDs().contains(paneID) {
                    if removePane(&tab.rootPane, target: paneID) {
                        if tab.zoomedPaneID == paneID { tab.zoomedPaneID = nil }
                        snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
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
            // Caller (the branch) is responsible for collapsing into the sibling.
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
            for tab in workspace.tabs {
                if let leaf = leaf(in: tab.rootPane, paneID: srcID) { srcLeaf = leaf }
                if let leaf = leaf(in: tab.rootPane, paneID: dstID) { dstLeaf = leaf }
            }
        }
        guard let src = srcLeaf, let dst = dstLeaf else { return false }
        for workspaceIndex in snapshot.workspaces.indices {
            for tabIndex in snapshot.workspaces[workspaceIndex].tabs.indices {
                var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
                replaceLeaf(in: &tab.rootPane, paneID: src.id, with: dst)
                replaceLeaf(in: &tab.rootPane, paneID: dst.id, with: src)
                snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
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
            for tabIndex in snapshot.workspaces[workspaceIndex].tabs.indices {
                var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
                guard tab.rootPane.allPaneIDs().contains(paneID) else { continue }
                tab.zoomedPaneID = (tab.zoomedPaneID == paneID) ? nil : paneID
                snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
                bumpRevision()
                return true
            }
        }
        return false
    }

    public mutating func resizePane(_ paneID: PaneID, direction: ResizeDirection, amount: Int) -> Bool {
        for workspaceIndex in snapshot.workspaces.indices {
            for tabIndex in snapshot.workspaces[workspaceIndex].tabs.indices {
                var tab = snapshot.workspaces[workspaceIndex].tabs[tabIndex]
                guard tab.rootPane.allPaneIDs().contains(paneID) else { continue }
                let delta = CGFloat(amount) * 0.05
                let signed: CGFloat
                switch direction {
                case .left, .up: signed = -delta
                case .right, .down: signed = delta
                }
                _ = adjustRatio(&tab.rootPane, target: paneID, delta: signed)
                snapshot.workspaces[workspaceIndex].tabs[tabIndex] = tab
                bumpRevision()
                return true
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

    public mutating func setAgent(_ agent: AgentSnapshot?, forSurfaceKey key: String) {
        guard let match = tab(forSurfaceKey: key),
              let workspaceIndex = snapshot.workspaces.firstIndex(where: { $0.id == match.workspaceID }),
              let tabIndex = snapshot.workspaces[workspaceIndex].tabs.firstIndex(where: { $0.id == match.tabID })
        else { return }
        snapshot.workspaces[workspaceIndex].tabs[tabIndex].agent = agent
        bumpRevision()
    }

    public func listSurfaces() -> [SurfaceSummary] {
        var result: [SurfaceSummary] = []
        for workspace in snapshot.workspaces {
            for tab in workspace.tabs {
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
        return result
    }
}
