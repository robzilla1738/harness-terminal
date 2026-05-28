import AppKit
import HarnessCore

/// `CommandExecutor` implementation for the GUI app. Translates every
/// high-level `Command` into the appropriate `SessionCoordinator` call (or
/// for not-yet-implemented commands, raises `unsupportedInThisContext` so the
/// user sees a clear error in the `:` prompt instead of a silent no-op).
///
/// Phases 3-6 add cases for copy-mode, options, hooks, buffers, layouts, etc.;
/// the executor grows alongside those phases.
@MainActor
final class MainExecutor: CommandExecutor {
    static let shared = MainExecutor()

    private init() {}

    nonisolated func execute(_ command: Command) throws {
        // Funnel onto the main actor — IPC and AppKit calls all want it.
        if Thread.isMainThread {
            try MainActor.assumeIsolated { try self.dispatch(command) }
        } else {
            var resultError: Error?
            DispatchQueue.main.sync {
                do { try MainActor.assumeIsolated { try self.dispatch(command) } }
                catch { resultError = error }
            }
            if let resultError { throw resultError }
        }
    }

    @MainActor
    private func dispatch(_ command: Command) throws {
        let coordinator = SessionCoordinator.shared
        switch command {
        case .splitWindow(let direction):
            coordinator.splitActivePane(direction: direction)
        case .killPane:
            coordinator.killActivePane()
        case .zoomPane:
            coordinator.zoomActivePane()
        case .selectPane(let target):
            try selectPane(target: target, coordinator: coordinator)
        case .swapPane:
            // Pane targets for swap-pane (next/previous) translate to swapping
            // with the next/previous pane in flat order.
            guard let workspace = coordinator.snapshot.activeWorkspace,
                  let tab = workspace.activeTab,
                  let sid = coordinator.activeSurfaceID,
                  let activePane = panePathLookup(surfaceID: sid, in: tab.rootPane)
            else { throw CommandExecutionError.noActiveSurface }
            let panes = tab.rootPane.allPaneIDs()
            guard panes.count >= 2, let idx = panes.firstIndex(of: activePane) else { return }
            let nextIdx = (idx + 1) % panes.count
            coordinator.requestDaemon(.swapPanes(srcPaneID: activePane, dstPaneID: panes[nextIdx]))
            coordinator.syncFromDaemon()
        case .resizePane(let direction, let amount):
            try resizeActivePane(direction: direction, amount: amount, coordinator: coordinator)
        case .newWindow:
            coordinator.openTabInActiveWorkspace()
        case .killWindow:
            if let tabID = coordinator.snapshot.activeWorkspace?.activeTab?.id {
                coordinator.requestDaemon(.closeTab(tabID: tabID))
                coordinator.syncFromDaemon()
            }
        case .renameWindow(let newName):
            if let newName, let tabID = coordinator.snapshot.activeWorkspace?.activeTab?.id {
                coordinator.requestDaemon(.renameTab(tabID: tabID, name: newName))
                coordinator.syncFromDaemon()
            } else {
                coordinator.beginRenameActiveTab()
            }
        case .nextWindow:
            cycleActiveTab(coordinator: coordinator, forward: true)
        case .previousWindow:
            cycleActiveTab(coordinator: coordinator, forward: false)
        case .selectWindow(let index):
            selectTab(coordinator: coordinator, atIndex: index)
        case .newSession(let name):
            if let workspaceID = coordinator.snapshot.activeWorkspaceID {
                coordinator.addSession(to: workspaceID, name: name)
            }
        case .killSession:
            if let sessionID = coordinator.snapshot.activeWorkspace?.activeSessionID {
                coordinator.requestDaemon(.closeSession(sessionID: sessionID))
                coordinator.syncFromDaemon()
            }
        case .renameSession(let newName):
            if let newName, let sessionID = coordinator.snapshot.activeWorkspace?.activeSessionID {
                coordinator.requestDaemon(.renameSession(sessionID: sessionID, name: newName))
                coordinator.syncFromDaemon()
            }
        case .selectWorkspace(let index):
            coordinator.selectWorkspace(byIndex: index)
        case .nextWorkspace, .previousWorkspace:
            cycleActiveWorkspace(coordinator: coordinator, forward: command == .nextWorkspace)
        case .copyMode:
            coordinator.toggleCopyMode()
        case .detachClient:
            coordinator.detachActiveSurface()
        case .sendKeys(let keys):
            guard let surfaceID = coordinator.activeSurfaceID else {
                throw CommandExecutionError.noActiveSurface
            }
            coordinator.requestDaemon(.sendKeys(surfaceID: surfaceID.uuidString, keys: keys))
        case .displayMessage(let format):
            DisplayMessage.show(format)
        case .runShell(let shellCommand):
            try RunShell.fireAndForget(shellCommand)
        case .bindKey(let table, let spec, let inner):
            try KeybindingsService.shared.bind(table: KeyTableID(rawValue: table), specRaw: spec, command: inner)
            PrefixKeymap.shared.rebuildFromSettings()
        case .unbindKey(let table, let spec):
            try KeybindingsService.shared.unbind(table: KeyTableID(rawValue: table), specRaw: spec)
            PrefixKeymap.shared.rebuildFromSettings()
        case .listKeys(let table):
            DisplayMessage.show(KeybindingsService.shared.summary(table: table.map { KeyTableID(rawValue: $0) }))
        case .sourceConfig:
            coordinator.reimportFromGhostty()
        case .reloadKeybindings:
            KeybindingsService.shared.reload()
            PrefixKeymap.shared.rebuildFromSettings()
        case .showCheatsheet:
            PrefixCheatsheetWindow.shared.toggle()
        case .sequence(let commands):
            for command in commands { try execute(command) }
        case .selectLayout(let name):
            try applyLayout(name: name, coordinator: coordinator)
        case .nextLayout:
            try cycleLayout(forward: true, coordinator: coordinator)
        case .previousLayout:
            try cycleLayout(forward: false, coordinator: coordinator)
        case .rotateWindow(let forward):
            guard let tabID = coordinator.snapshot.activeWorkspace?.activeTab?.id else {
                throw CommandExecutionError.noActiveSurface
            }
            coordinator.requestDaemon(.rotatePanes(tabID: tabID, forward: forward))
            coordinator.syncFromDaemon()
        case .breakPane:
            try breakActivePane(coordinator: coordinator)
        case .respawnPane(let keepHistory):
            guard let sid = coordinator.activeSurfaceID else { throw CommandExecutionError.noActiveSurface }
            coordinator.requestDaemon(.respawnPane(surfaceID: sid.uuidString, keepHistory: keepHistory))
        }
    }

    @MainActor
    private func applyLayout(name: String, coordinator: SessionCoordinator) throws {
        guard let tabID = coordinator.snapshot.activeWorkspace?.activeTab?.id else {
            throw CommandExecutionError.noActiveSurface
        }
        let activePaneID = coordinator.activeSurfaceID.flatMap { sid in
            coordinator.snapshot.activeWorkspace?.activeTab.flatMap { panePathLookup(surfaceID: sid, in: $0.rootPane) }
        }
        coordinator.requestDaemon(.applyLayout(tabID: tabID, layout: name, mainPaneID: activePaneID))
        coordinator.syncFromDaemon()
    }

    @MainActor
    private func cycleLayout(forward: Bool, coordinator: SessionCoordinator) throws {
        guard let tabID = coordinator.snapshot.activeWorkspace?.activeTab?.id else {
            throw CommandExecutionError.noActiveSurface
        }
        coordinator.requestDaemon(forward ? .nextLayout(tabID: tabID) : .previousLayout(tabID: tabID))
        coordinator.syncFromDaemon()
    }

    @MainActor
    private func breakActivePane(coordinator: SessionCoordinator) throws {
        guard let tab = coordinator.snapshot.activeWorkspace?.activeTab,
              let sid = coordinator.activeSurfaceID,
              let paneID = panePathLookup(surfaceID: sid, in: tab.rootPane)
        else { throw CommandExecutionError.noActiveSurface }
        coordinator.requestDaemon(.breakPane(paneID: paneID))
        coordinator.syncFromDaemon()
    }

    @MainActor
    private func selectPane(target: Command.PaneTarget, coordinator: SessionCoordinator) throws {
        switch target {
        case .next: coordinator.cycleActivePane(forward: true)
        case .previous, .last: coordinator.cycleActivePane(forward: false)
        case .left, .right, .up, .down:
            guard let tab = coordinator.snapshot.activeWorkspace?.activeTab,
                  let sid = coordinator.activeSurfaceID,
                  let paneID = panePathLookup(surfaceID: sid, in: tab.rootPane)
            else { return }
            let axis: DirectionalAxis
            switch target {
            case .left: axis = .left
            case .right: axis = .right
            case .up: axis = .up
            case .down: axis = .down
            default: return
            }
            let response = coordinator.requestDaemon(.selectPaneDirectional(currentPaneID: paneID, direction: axis))
            if case let .paneID(neighbor) = response,
               let neighborSurface = neighborSurface(paneID: neighbor, in: tab.rootPane) {
                coordinator.setActiveSurface(neighborSurface)
            }
        }
    }

    @MainActor
    private func neighborSurface(paneID: PaneID, in node: PaneNode) -> SurfaceID? {
        switch node {
        case let .leaf(leaf): return leaf.id == paneID ? leaf.surfaceID : nil
        case let .branch(_, _, first, second):
            return neighborSurface(paneID: paneID, in: first) ?? neighborSurface(paneID: paneID, in: second)
        }
    }

    @MainActor
    private func resizeActivePane(direction: ResizeDirection, amount: Int, coordinator: SessionCoordinator) throws {
        guard let workspace = coordinator.snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let surfaceID = coordinator.activeSurfaceID,
              let paneID = panePathLookup(surfaceID: surfaceID, in: tab.rootPane)
        else { throw CommandExecutionError.noActiveSurface }
        coordinator.requestDaemon(.resizePane(paneID: paneID, direction: direction, amount: amount))
        coordinator.syncFromDaemon(metadataOnly: true)
    }

    @MainActor
    private func cycleActiveTab(coordinator: SessionCoordinator, forward: Bool) {
        guard let workspace = coordinator.snapshot.activeWorkspace,
              let session = workspace.activeSession,
              !session.tabs.isEmpty,
              let activeTab = workspace.activeTab,
              let currentIdx = session.tabs.firstIndex(where: { $0.id == activeTab.id })
        else { return }
        let nextIdx = (currentIdx + (forward ? 1 : -1) + session.tabs.count) % session.tabs.count
        coordinator.requestDaemon(.selectTab(workspaceID: workspace.id, tabID: session.tabs[nextIdx].id))
        coordinator.syncFromDaemon()
    }

    @MainActor
    private func selectTab(coordinator: SessionCoordinator, atIndex index: Int) {
        guard let workspace = coordinator.snapshot.activeWorkspace,
              let session = workspace.activeSession,
              index >= 0, index < session.tabs.count
        else { return }
        coordinator.requestDaemon(.selectTab(workspaceID: workspace.id, tabID: session.tabs[index].id))
        coordinator.syncFromDaemon()
    }

    @MainActor
    private func cycleActiveWorkspace(coordinator: SessionCoordinator, forward: Bool) {
        let workspaces = coordinator.snapshot.workspaces
        guard !workspaces.isEmpty,
              let currentID = coordinator.snapshot.activeWorkspaceID,
              let idx = workspaces.firstIndex(where: { $0.id == currentID })
        else { return }
        let nextIdx = (idx + (forward ? 1 : -1) + workspaces.count) % workspaces.count
        coordinator.selectWorkspace(workspaces[nextIdx].id)
    }

    @MainActor
    private func panePathLookup(surfaceID: SurfaceID, in node: PaneNode) -> PaneID? {
        switch node {
        case let .leaf(leaf): return leaf.surfaceID == surfaceID ? leaf.id : nil
        case let .branch(_, _, first, second):
            return panePathLookup(surfaceID: surfaceID, in: first)
                ?? panePathLookup(surfaceID: surfaceID, in: second)
        }
    }
}

// MARK: - Side-effect helpers

@MainActor
enum DisplayMessage {
    /// Lightweight transient toast. Phase 5 will replace this with a styled
    /// status-line popover; for now we surface it via an alert-style notice.
    static func show(_ format: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = format
        alert.runModal()
    }
}

@MainActor
enum RunShell {
    /// Fire-and-forget shell execution. Phase 6 wires `-b` to capture stdout
    /// into a paste buffer; this implementation just runs and drops output.
    static func fireAndForget(_ command: String) throws {
        let shell = SessionCoordinator.shared.settings.defaultShell.isEmpty
            ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            : SessionCoordinator.shared.settings.defaultShell
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
    }
}
