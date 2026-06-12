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
            // Off-main callers must NOT be holding the main thread when they call this (it would
            // deadlock on `main.sync`). In practice every caller — prefix keymap, command prompt,
            // menus, hook-branch completions — runs on a background queue that is not blocking
            // main, or is already on main (the branch above). Keep this invariant if adding callers.
            var resultError: Error?
            DispatchQueue.main.sync {
                do { try MainActor.assumeIsolated { try self.dispatch(command) } }
                catch { resultError = error }
            }
            if let resultError { throw resultError }
        }
    }

    /// Run a command for the fire-and-forget paths (hook branches, confirm-before, menu items,
    /// sourced config) that previously swallowed the throw with `try?`. Surfaces any failure as a
    /// transient toast so a mistyped binding/command isn't a silent no-op. `nonisolated` so it's
    /// callable from any closure context; the toast hops to the main actor.
    nonisolated func executeSurfacingErrors(_ command: Command) {
        do {
            try execute(command)
        } catch {
            let message = "error: \(error)"
            DispatchQueue.main.async { MainActor.assumeIsolated { DisplayMessage.show(message) } }
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
            // Route through the shared translator so next/previous/last and `-s`
            // resolve identically to the CLI, compositor, and control mode (the
            // old inline handler always swapped with the next pane).
            try runViaTranslator(command, coordinator: coordinator)
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
        case .moveWindow, .swapWindow:
            // Route through the shared translator so the `-t :N` window NUMBER is mapped to an
            // array position with base-index applied — identical to the CLI, compositor, and hook
            // executor. The old inline handlers passed the raw number straight to reorderTab/swapTab,
            // landing one slot off select-window under a non-zero `base-index`.
            try runViaTranslator(command, coordinator: coordinator)
        case .newSession(let name):
            if let workspaceID = coordinator.snapshot.activeWorkspaceID {
                // tmux `new-session` starts in the default directory (not the active
                // tab's), so pass it explicitly rather than inheriting the cwd.
                coordinator.addSession(to: workspaceID, cwd: coordinator.settings.defaultCWD, name: name)
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
        case .nextSession:
            cycleActiveSession(coordinator: coordinator, forward: true)
        case .previousSession:
            cycleActiveSession(coordinator: coordinator, forward: false)
        case .selectSession(let index):
            selectSession(coordinator: coordinator, atIndex: index)
        case .selectWorkspace(let index):
            coordinator.selectWorkspace(byIndex: index)
        case .nextWorkspace, .previousWorkspace:
            cycleActiveWorkspace(coordinator: coordinator, forward: command == .nextWorkspace)
        case .copyMode:
            coordinator.toggleCopyMode()
        case let .copyModeCommand(action):
            coordinator.performCopyModeAction(action)
        case .detachClient:
            coordinator.detachActiveSurface()
        case .reattachSurface:
            coordinator.reattachActiveSurface()
        case .jumpToPreviousPrompt:
            coordinator.jumpToPreviousPrompt()
        case .jumpToNextPrompt:
            coordinator.jumpToNextPrompt()
        case .selectLastCommandOutput:
            coordinator.selectLastCommandOutput()
        case .sendKeys(let keys):
            guard let surfaceID = coordinator.activeSurfaceID else {
                throw CommandExecutionError.noActiveSurface
            }
            coordinator.requestDaemon(.sendKeys(surfaceID: surfaceID.uuidString, keys: keys))
        case .sendKeysLiteral(let text):
            guard let surfaceID = coordinator.activeSurfaceID else { throw CommandExecutionError.noActiveSurface }
            coordinator.requestDaemon(.sendData(surfaceID: surfaceID.uuidString, data: Data(text.utf8)))
        case .sendKeysHex(let hex):
            guard let surfaceID = coordinator.activeSurfaceID else { throw CommandExecutionError.noActiveSurface }
            let bytes = hex.compactMap { tok -> UInt8? in
                UInt8(tok.hasPrefix("0x") || tok.hasPrefix("0X") ? String(tok.dropFirst(2)) : tok, radix: 16)
            }
            coordinator.requestDaemon(.sendData(surfaceID: surfaceID.uuidString, data: Data(bytes)))
        case .displayMessage(let format):
            DisplayMessage.show(format)
        case .displayMessagePrint(let format):
            // The GUI client has no stdout to print to, so `-p` surfaces the message like a normal
            // display-message (the visual surface is the GUI's "output").
            DisplayMessage.show(format)
        case .runShell(let shellCommand, let captureToBuffer):
            RunShell.run(shellCommand, captureToBuffer: captureToBuffer)
        case .ifShell(let condition, let then, let otherwise):
            RunShell.runConditional(condition) { success in
                let branch = success ? then : otherwise
                guard let branch else { return }
                MainExecutor.shared.executeSurfacingErrors(branch)
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
        // Config / buffer / hook write verbs: resolve scope/session/pane against the GUI's
        // focus through the shared translator (same path as the compositor and hooks).
        case .setOption, .setEnvironment, .setBuffer, .pasteBuffer, .deleteBuffer,
             .setHook, .unbindHook:
            try runViaTranslator(command, coordinator: coordinator)
        // Show verbs: query the daemon and render through the message overlay (the same
        // surface list-keys uses).
        case let .showOptions(scope):
            if case let .options(items)? = coordinator.requestDaemon(.showOptions(scope: scope)) {
                let lines = items.map { entry in
                    "\(entry.scope)\(entry.target.map { "(\($0.prefix(8)))" } ?? "") \(entry.key) = \(entry.value)"
                }
                DisplayMessage.show(lines.isEmpty ? "no options set" : lines.joined(separator: "\n"))
            }
        case let .showEnvironment(global):
            let sessionID = global ? nil : coordinator.snapshot.activeWorkspace?.activeSession?.id
            if case let .options(items)? = coordinator.requestDaemon(.showEnvironment(sessionID: sessionID)) {
                let lines = items.map { "\($0.key)=\($0.value)" }
                DisplayMessage.show(lines.isEmpty ? "no environment entries" : lines.joined(separator: "\n"))
            }
        case .listBuffers:
            if case let .buffers(buffers)? = coordinator.requestDaemon(.listBuffers) {
                let lines = buffers.map { "\($0.name): \($0.byteCount) bytes: \"\($0.preview)\"" }
                DisplayMessage.show(lines.isEmpty ? "no buffers" : lines.joined(separator: "\n"))
            }
        case let .showBuffer(name):
            if case let .buffer(buffer)? = coordinator.requestDaemon(.getBuffer(name: name)) {
                let text = buffer.data.map { String(decoding: $0, as: UTF8.self) } ?? buffer.preview
                DisplayMessage.show(text.isEmpty ? "buffer is empty" : text)
            } else {
                DisplayMessage.show("no such buffer")
            }
        case let .showHooks(event):
            if case let .hooks(hooks)? = coordinator.requestDaemon(.listHooks(event: event)) {
                let lines = hooks.map { "\($0.event) → \($0.commandSource)  [\($0.id.uuidString.prefix(8))]" }
                DisplayMessage.show(lines.isEmpty ? "no hooks bound" : lines.joined(separator: "\n"))
            }
        case .refreshClient:
            coordinator.syncFromDaemon()
        case .respawnWindow:
            try runViaTranslator(command, coordinator: coordinator)
        case .showMessages:
            if case let .text(log)? = coordinator.requestDaemon(.showMessages) {
                DisplayMessage.show(log.isEmpty ? "no messages" : log)
            }
        case let .findWindow(pattern, name, content, title, scopeTarget):
            // Non-content searches translate to a selectTab request; -C needs live
            // captures, done inline (re-dispatching the clientLocal result would loop).
            guard content else { return try runViaTranslator(command, coordinator: coordinator) }
            let match = FindWindowMatcher.firstMatch(
                coordinator.snapshot, pattern: pattern, name: name, title: title,
                target: scopeTarget, current: coordinator.snapshot.activeWorkspace?.activeSession
            ) { surfaceID in
                guard case let .text(text)? = coordinator.requestDaemon(
                    .capturePane(surfaceID: surfaceID, includeScrollback: false)) else { return nil }
                return text
            }
            guard let match else {
                DisplayMessage.show("find-window: no matches for '\(pattern)'")
                return
            }
            _ = coordinator.requestDaemon(.selectTab(workspaceID: match.workspaceID, tabID: match.tabID))
            coordinator.syncFromDaemon()
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
        case .clearHistory:
            guard let sid = coordinator.activeSurfaceID else { throw CommandExecutionError.noActiveSurface }
            coordinator.requestDaemon(.clearHistory(surfaceID: sid.uuidString))
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
            Phase67UI.confirmBefore(prompt: prompt) { MainExecutor.shared.executeSurfacingErrors(inner) }
        case .choose(let scope):
            Phase67UI.presentChoose(scope: scope, coordinator: coordinator)
        case .pipePane(let shellCommand):
            guard let sid = coordinator.activeSurfaceID else { throw CommandExecutionError.noActiveSurface }
            coordinator.requestDaemon(.pipePane(surfaceID: sid.uuidString, shellCommand: shellCommand))
        case .lockClient:
            Phase67UI.lock()
        case .clockMode:
            Phase67UI.toggleClock()
        case .switchClientTable(let table):
            PrefixKeymap.shared.switchClientTable(KeyTableID(rawValue: table))
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
            // Daemon validation errors (unknown hook event, bad option scope, …) must
            // reach the user — a silently-dropped .error reads as success (fail-loud
            // policy). First error aborts the remainder.
            for request in requests {
                if case let .error(message)? = coordinator.requestDaemon(request) {
                    coordinator.syncFromDaemon()
                    throw CommandExecutionError.daemonError(message)
                }
            }
            coordinator.syncFromDaemon()
        case let .clientLocal(local):
            try dispatch(local)
        case .unresolved:
            // find-window's no-match is a search result, not a focus problem — say so
            // (matches the -C path and the compositor/control-mode wording).
            if case let .findWindow(pattern, _, _, _, _) = command {
                DisplayMessage.show("find-window: no matches for '\(pattern)'")
                return
            }
            // Distinguish "you named something that doesn't exist" (strict `-t`/`-s`
            // resolution) from "there is nothing focused to act on".
            if case let .targeted(spec, _) = command {
                throw CommandExecutionError.targetNotFound(spec.raw)
            }
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
            // Surface a bad line instead of silently skipping it, but keep sourcing the rest.
            do { try executeSource(line) }
            catch { DisplayMessage.show("source: \(line): \(error)") }
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
        case .current: break // already focused — explicit no-op
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
    private func cycleActiveSession(coordinator: SessionCoordinator, forward: Bool) {
        guard let workspace = coordinator.snapshot.activeWorkspace,
              let activeSessionID = workspace.activeSessionID,
              let currentIdx = workspace.sessions.firstIndex(where: { $0.id == activeSessionID }),
              !workspace.sessions.isEmpty
        else { return }
        let nextIdx = (currentIdx + (forward ? 1 : -1) + workspace.sessions.count) % workspace.sessions.count
        coordinator.selectSession(workspaceID: workspace.id, sessionID: workspace.sessions[nextIdx].id)
    }

    @MainActor
    private func selectSession(coordinator: SessionCoordinator, atIndex index: Int) {
        guard let workspace = coordinator.snapshot.activeWorkspace,
              index >= 0, index < workspace.sessions.count
        else { return }
        coordinator.selectSession(workspaceID: workspace.id, sessionID: workspace.sessions[index].id)
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
    /// `display-time` cache: a synchronous show-options IPC round-trip per toast
    /// blocked the main actor (hook bursts fire many). The value changes rarely —
    /// re-read at most every few seconds, like the compositor's applyOptions cache.
    private static var cachedDisplayTimeMS = 750
    private static var displayTimeFetchedAt = Date.distantPast

    /// Non-blocking transient toast anchored to the active window, with the
    /// message run through the `FormatString` evaluator so tokens like
    /// `#{pane_title}` / `#{session_name}` resolve (matching the status line).
    static func show(_ format: String) {
        let rendered = FormatString.evaluate(format, context: SessionCoordinator.shared.currentFormatContext())
        guard let host = (NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.contentView != nil }))?.contentView else { return }
        // `display-time` (ms, tmux) bounds the toast hold, same as the compositor's flash.
        if Date().timeIntervalSince(displayTimeFetchedAt) > 5 {
            displayTimeFetchedAt = Date()
            cachedDisplayTimeMS = SessionCoordinator.shared.requestDaemon(.showOptions(scope: nil)).flatMap { response -> Int? in
                guard case let .options(entries) = response else { return nil }
                return entries.first { $0.key == "display-time" }.flatMap { Int($0.value) }
            } ?? 750
        }
        Toast.show(rendered, in: host, hold: max(Double(cachedDisplayTimeMS) / 1000, 0.1))
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
            // Only stdout is captured, and only with -b; stderr is never used. Route every UNUSED
            // stream to /dev/null instead of an undrained Pipe: an unread pipe that fills (~64 KiB)
            // blocks the child on write() so it never exits, deadlocking readDataToEndOfFile()/
            // waitUntilExit() and permanently leaking this GCD worker thread.
            let out: Pipe? = captureToBuffer ? Pipe() : nil
            if let out {
                process.standardOutput = out
            } else {
                process.standardOutput = FileHandle.nullDevice
            }
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                // A launch failure (bad shell path) is rare but otherwise invisible — surface it.
                DispatchQueue.main.async { MainActor.assumeIsolated { DisplayMessage.show("run-shell failed: \(error.localizedDescription)") } }
                return
            }
            let data = out?.fileHandleForReading.readDataToEndOfFile() ?? Data()
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
            // if-shell only needs the exit status — discard output to /dev/null. Undrained Pipes
            // would deadlock waitUntilExit() once the child writes >64 KiB to either stream (the
            // child blocks on a full pipe and never exits), hanging the branch and leaking a thread.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
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
