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
            // `Command.SplitDirection` is divider-orientation (`.vertical` =
            // side-by-side, the CommandParser convention); `splitActivePane`
            // wants the layout direction. Invert through the one shared rule so
            // prefix-`%` splits side-by-side, matching the compositor and tmux.
            coordinator.splitActivePane(direction: CommandIPCTranslator.layoutDirection(for: direction))
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
        case .markPane(let set):
            coordinator.setMarkedPane(set)
        case .joinPane(let direction):
            coordinator.joinMarkedPane(direction: direction)
        case .synchronizePanes(let set):
            coordinator.setSynchronizePanes(set)
        case .displayPanes:
            coordinator.showDisplayPanes()
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
        case .moveWindow(let index):
            if let workspace = coordinator.snapshot.activeWorkspace,
               let tabID = workspace.activeTab?.id {
                coordinator.requestDaemon(.reorderTab(workspaceID: workspace.id, tabID: tabID, toIndex: index))
                coordinator.syncFromDaemon()
            }
        case .swapWindow(let index):
            if let workspace = coordinator.snapshot.activeWorkspace,
               let tabID = workspace.activeTab?.id {
                coordinator.requestDaemon(.swapTab(workspaceID: workspace.id, tabID: tabID, withIndex: index))
                coordinator.syncFromDaemon()
            }
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
        case .runShell(let shellCommand, let captureToBuffer):
            RunShell.run(shellCommand, captureToBuffer: captureToBuffer)
        case .ifShell(let condition, let then, let otherwise):
            RunShell.runConditional(condition) { success in
                let branch = success ? then : otherwise
                guard let branch else { return }
                try? MainExecutor.shared.execute(branch)
            }
        case .bindKey(let table, let spec, let inner, let repeatable):
            try KeybindingsService.shared.bind(table: KeyTableID(rawValue: table), specRaw: spec, command: inner, repeatable: repeatable)
            PrefixKeymap.shared.rebuildFromSettings()
        case .unbindKey(let table, let spec):
            try KeybindingsService.shared.unbind(table: KeyTableID(rawValue: table), specRaw: spec)
            PrefixKeymap.shared.rebuildFromSettings()
        case .listKeys(let table):
            DisplayMessage.show(KeybindingsService.shared.summary(table: table.map { KeyTableID(rawValue: $0) }))
        case .sourceConfig:
            coordinator.reimportTerminalConfig()
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
        case let .movePane(direction, source):
            try runViaTranslator(.movePane(direction: direction, source: source), coordinator: coordinator)
        case .renumberWindows:
            try runViaTranslator(.renumberWindows, coordinator: coordinator)

        // MARK: Phase 6/7
        case .lastWindow:
            guard let workspace = coordinator.snapshot.activeWorkspace,
                  let session = workspace.activeSession,
                  let last = session.lastActiveTabID,
                  session.tabs.contains(where: { $0.id == last })
            else { return }
            coordinator.selectTab(workspaceID: workspace.id, tabID: last)
        case .sendPrefix:
            sendPrefix(coordinator: coordinator)
        case .sourceFile(let path):
            try sourceFile(path: path)
        case .commandPrompt(let prompts, let template):
            CommandPromptController.shared.presentTemplate(prompts: prompts, template: template)
        case .confirmBefore(let prompt, let inner):
            Phase67UI.confirmBefore(prompt: prompt) { try? MainExecutor.shared.execute(inner) }
        case .choose(let scope):
            Phase67UI.presentChoose(scope: scope, coordinator: coordinator)
        case .pipePane(let shellCommand):
            guard let sid = coordinator.activeSurfaceID else { throw CommandExecutionError.noActiveSurface }
            coordinator.requestDaemon(.pipePane(surfaceID: sid.uuidString, shellCommand: shellCommand))
        case .lockClient:
            Phase67UI.lock()
        case .clockMode:
            Phase67UI.toggleClock()
        case .linkWindow(let targetSessionName):
            linkWindow(targetSessionName: targetSessionName, coordinator: coordinator)
        case .unlinkWindow:
            if let tabID = coordinator.snapshot.activeWorkspace?.activeTab?.id {
                coordinator.requestDaemon(.unlinkWindow(tabID: tabID))
                coordinator.syncFromDaemon()
            }
        case .displayPopup(let command):
            Phase67UI.presentPopup(command: command, coordinator: coordinator)
        case .displayMenu(let items):
            Phase67UI.presentMenu(items: items)
        case let .targeted(spec, inner):
            try runViaTranslator(.targeted(spec, inner), coordinator: coordinator)
        }
    }

    // MARK: Targeting

    /// Run a command through the shared `CommandIPCTranslator` against the GUI's
    /// active focus — the same resolution the CLI, compositor, and hook executor
    /// use. Structural results go straight to the daemon; client-local inner verbs
    /// (UI overlays) fall back to normal dispatch. Used for `-t`-targeted commands
    /// and for verbs (move-pane, renumber-windows) whose resolution already lives
    /// in the translator.
    @MainActor
    private func runViaTranslator(_ command: Command, coordinator: SessionCoordinator) throws {
        let baseIndex = optionInt("base-index", default: 0, coordinator: coordinator)
        let paneBaseIndex = optionInt("pane-base-index", default: 0, coordinator: coordinator)
        let activeTab = coordinator.snapshot.activeWorkspace?.activeTab
        let activePane = coordinator.activeSurfaceID.flatMap { sid in
            activeTab.flatMap { panePathLookup(surfaceID: sid, in: $0.rootPane) }
        }
        let markedPane = coordinator.markedSurfaceID.flatMap { sid in
            activeTab.flatMap { panePathLookup(surfaceID: sid, in: $0.rootPane) }
        }
        let focus = CommandTarget(
            snapshot: coordinator.snapshot,
            focusedWorkspaceID: coordinator.snapshot.activeWorkspaceID,
            focusedTabID: activeTab?.id,
            focusedPaneID: activePane,
            markedPaneID: markedPane
        )
        switch CommandIPCTranslator.translate(command, target: focus, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex) {
        case let .requests(requests):
            for request in requests { _ = coordinator.requestDaemon(request) }
            coordinator.syncFromDaemon()
        case let .clientLocal(local):
            try dispatch(local)
        case .unresolved:
            throw CommandExecutionError.noActiveSurface
        }
    }

    @MainActor
    private func optionInt(_ key: String, default fallback: Int, coordinator: SessionCoordinator) -> Int {
        guard case let .options(entries)? = coordinator.requestDaemon(.showOptions(scope: nil)) else { return fallback }
        return entries.first { $0.key == key }.flatMap { Int($0.value) } ?? fallback
    }

    // MARK: Phase 6/7 helpers

    @MainActor
    private func sendPrefix(coordinator: SessionCoordinator) {
        guard let sid = coordinator.activeSurfaceID else { return }
        // Send the configured prefix as a raw byte (C-<letter> → control code).
        guard let spec = KeySpec.parse(coordinator.settings.prefixKey),
              spec.modifiers.contains(.control),
              let letter = spec.key.lowercased().unicodeScalars.first,
              letter.value >= 0x61, letter.value <= 0x7a
        else { return }
        let byte = UInt8(letter.value - 0x60)
        coordinator.requestDaemon(.sendData(surfaceID: sid.uuidString, data: Data([byte])))
    }

    @MainActor
    private func sourceFile(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        let contents = try String(contentsOfFile: expanded, encoding: .utf8)
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            try? executeSource(line)
        }
    }

    @MainActor
    private func linkWindow(targetSessionName: String, coordinator: SessionCoordinator) {
        guard let tabID = coordinator.snapshot.activeWorkspace?.activeTab?.id else { return }
        let match = coordinator.snapshot.workspaces.flatMap { $0.sessions }.first {
            $0.name == targetSessionName || $0.id.uuidString == targetSessionName
        }
        guard let session = match else { return }
        coordinator.requestDaemon(.linkWindow(tabID: tabID, targetSessionID: session.id))
        coordinator.syncFromDaemon()
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
        case .previous: coordinator.cycleActivePane(forward: false)
        case .last: coordinator.selectLastPane()
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
    /// Non-blocking transient toast anchored to the active window, with the
    /// message run through the `FormatString` evaluator so tokens like
    /// `#{pane_title}` / `#{session_name}` resolve (matching the status line).
    static func show(_ format: String) {
        let rendered = FormatString.evaluate(format, context: SessionCoordinator.shared.currentFormatContext())
        guard let host = (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.contentView != nil }))?.contentView else { return }
        Toast.show(rendered, in: host)
    }
}

@MainActor
enum RunShell {
    private static var loginShell: String {
        let s = SessionCoordinator.shared.settings.defaultShell
        return s.isEmpty ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : s
    }

    /// Run a shell command off the main thread. With `captureToBuffer`, stdout is
    /// stored in a paste buffer (`run-shell -b`); otherwise output is dropped.
    static func run(_ command: String, captureToBuffer: Bool) {
        let shell = loginShell
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", command]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            let data = captureToBuffer ? out.fileHandleForReading.readDataToEndOfFile() : Data()
            process.waitUntilExit()
            if captureToBuffer, !data.isEmpty {
                DispatchQueue.main.async {
                    _ = SessionCoordinator.shared.requestDaemon(.setBuffer(name: nil, data: data))
                }
            }
        }
    }

    /// Run a shell command and call `completion(success)` on the main thread with
    /// `success == (exit code 0)`, for `if-shell` branching.
    static func runConditional(_ command: String, completion: @escaping @MainActor (Bool) -> Void) {
        let shell = loginShell
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-lc", command]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            let success: Bool
            if (try? process.run()) != nil {
                process.waitUntilExit()
                success = process.terminationStatus == 0
            } else {
                success = false
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(success) } }
        }
    }
}
