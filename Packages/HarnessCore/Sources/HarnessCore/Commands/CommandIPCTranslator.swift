import Foundation

/// A value snapshot of *what a client is focused on*, used to resolve
/// target-less commands (split the focused pane, kill the focused pane, select
/// the focused tab's neighbor, …) into concrete `IPCRequest`s.
///
/// Focus is server-authoritative after Phase 2: a `Tab` carries `activePaneID`
/// and a session carries `activeTabID`, so when a client doesn't pin a specific
/// focus it falls back to the snapshot's active chain. The attach-window
/// compositor pins `focusedTabID` (the window it is rendering) and tracks the
/// marked pane locally; the daemon's hook executor passes none and resolves the
/// global active chain.
public struct CommandTarget: Sendable {
    public var snapshot: SessionSnapshot
    public var focusedWorkspaceID: WorkspaceID?
    public var focusedTabID: TabID?
    public var focusedPaneID: PaneID?
    /// Marked pane (join-pane source). Client-tracked: tmux's `select-pane -m`.
    public var markedPaneID: PaneID?

    public init(
        snapshot: SessionSnapshot,
        focusedWorkspaceID: WorkspaceID? = nil,
        focusedTabID: TabID? = nil,
        focusedPaneID: PaneID? = nil,
        markedPaneID: PaneID? = nil
    ) {
        self.snapshot = snapshot
        self.focusedWorkspaceID = focusedWorkspaceID
        self.focusedTabID = focusedTabID
        self.focusedPaneID = focusedPaneID
        self.markedPaneID = markedPaneID
    }

    // MARK: Resolution

    public var workspace: Workspace? {
        if let focusedWorkspaceID, let ws = snapshot.workspaces.first(where: { $0.id == focusedWorkspaceID }) {
            return ws
        }
        if let focusedTabID {
            for ws in snapshot.workspaces where ws.sessions.contains(where: { $0.tabs.contains { $0.id == focusedTabID } }) {
                return ws
            }
        }
        return snapshot.activeWorkspace
    }

    public var session: SessionGroup? {
        guard let workspace else { return nil }
        if let focusedTabID, let s = workspace.sessions.first(where: { $0.tabs.contains { $0.id == focusedTabID } }) {
            return s
        }
        return workspace.activeSession
    }

    public var tab: Tab? {
        if let focusedTabID {
            for ws in snapshot.workspaces {
                for s in ws.sessions {
                    if let t = s.tabs.first(where: { $0.id == focusedTabID }) { return t }
                }
            }
        }
        return workspace?.activeTab
    }

    /// The focused pane: explicit focus, else the tab's server-side active pane,
    /// else the first leaf.
    public var paneID: PaneID? {
        if let focusedPaneID, let tab, tab.rootPane.allPaneIDs().contains(focusedPaneID) {
            return focusedPaneID
        }
        return tab?.activePaneID ?? tab?.rootPane.allPaneIDs().first
    }

    /// Flat pane order for the focused tab (depth-first, first-child-first).
    public var paneOrder: [PaneID] { tab?.rootPane.allPaneIDs() ?? [] }

    /// The pane `delta` steps from the focused pane, wrapping.
    public func pane(offset delta: Int) -> PaneID? {
        let order = paneOrder
        guard !order.isEmpty, let current = paneID, let idx = order.firstIndex(of: current) else {
            return order.first
        }
        let next = ((idx + delta) % order.count + order.count) % order.count
        return order[next]
    }

    /// The surface key backing a pane in the focused tab.
    public func surfaceID(of pane: PaneID) -> String? {
        guard let tab else { return nil }
        return Self.findLeaf(tab.rootPane, paneID: pane)?.surfaceID.uuidString
    }

    private static func findLeaf(_ node: PaneNode, paneID: PaneID) -> PaneLeaf? {
        switch node {
        case let .leaf(leaf): return leaf.id == paneID ? leaf : nil
        case let .branch(_, _, first, second):
            return findLeaf(first, paneID: paneID) ?? findLeaf(second, paneID: paneID)
        }
    }
}

/// The result of translating a `Command` against a `CommandTarget`.
public enum CommandTranslation: Sendable {
    /// Send these requests to the daemon, in order.
    case requests([IPCRequest])
    /// The command is client-local (UI overlay, mode toggle, marked-pane
    /// tracking, shell execution, keybinding-file edit, or a `sequence` the
    /// client should expand itself). The original `Command` is carried so the
    /// caller can dispatch it through its own front-end.
    case clientLocal(Command)
    /// A target was required (focused pane/tab/workspace) but none was resolvable.
    case unresolved
}

/// The single `Command` → `[IPCRequest]` mapping shared by every headless
/// front-end: the attach-window compositor and the daemon's hook executor both
/// drive the daemon through this, so a prefix verb, a `keybindings.json`
/// override, and a hook-fired command all behave identically. The GUI's
/// `MainExecutor` consults it for the split-direction rule and target resolution
/// while keeping its richer AppKit affordances (toasts, rename sheets).
///
/// **Split-direction rule (the one place it lives):** `Command.SplitDirection`
/// follows the `CommandParser` convention where `.vertical` means *a vertical
/// divider → panes side by side*; the layout `SplitDirection` used by `newSplit`
/// is the opposite (`.horizontal` = side-by-side, per the geometry invariant).
/// So command→layout is inverted exactly here, and every front-end that routes
/// through the translator gets it right.
public enum CommandIPCTranslator {
    /// Invert the command's divider-orientation `SplitDirection` into the layout
    /// `SplitDirection` the daemon stores.
    public static func layoutDirection(for commandDirection: SplitDirection) -> SplitDirection {
        commandDirection == .vertical ? .horizontal : .vertical
    }

    public static func translate(
        _ command: Command,
        target: CommandTarget,
        baseIndex: Int = 0,
        paneBaseIndex: Int = 0
    ) -> CommandTranslation {
        switch command {
        // MARK: Targeting — resolve `-t` then run the inner verb against it.
        case let .targeted(spec, inner):
            // STRICT: a named component that doesn't match makes the whole command
            // `.unresolved` — every targeted verb (kill/respawn/send-keys/…) fails
            // loudly on a bad `-t` instead of acting on the caller's focus.
            guard let resolved = target.resolving(
                spec, command: inner, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex
            ) else { return .unresolved }
            // For "select" verbs with an explicit target, selecting *is* focusing
            // the resolved window/pane (absolute), not a relative step.
            switch inner {
            case .selectPane:
                guard let tab = resolved.tab, let pane = resolved.paneID else { return .unresolved }
                return .requests([.selectPane(tabID: tab.id, paneID: pane)])
            case .selectWindow:
                guard let ws = resolved.workspace, let tab = resolved.tab else { return .unresolved }
                return .requests([.selectTab(workspaceID: ws.id, tabID: tab.id)])
            case let .newSession(name):
                // tmux `new-session -t <session>`: a session GROUPED with the target,
                // sharing its window list — not a session created "at" the target.
                // STRICT lookup, like `resolving` itself: never group with the wrong
                // session — the misroute class the v1.7.1 validation eliminated.
                guard let sref = spec.session,
                      let (_, targetSession) = CommandTarget.findSession(sref, in: target.snapshot, current: target.session)
                else { return .unresolved }
                return .requests([.newSessionInGroup(targetSessionID: targetSession.id, name: name)])
            case let .swapPane(_, source):
                // tmux `swap-pane [-s src] -t X`: X names the DESTINATION; the pane to
                // act from is `-s` (default: the caller's active pane). Translating
                // against `resolved` would swap X with X's own neighbor.
                guard let src = swapSource(source, target: target, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex),
                      let dst = resolved.paneID, dst != src else {
                    return .unresolved
                }
                return .requests([.swapPanes(srcPaneID: src, dstPaneID: dst)])
            default:
                return translate(inner, target: resolved, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex)
            }

        // MARK: Config / buffer / hook verbs
        case let .setOption(scope, explicitTarget, key, rawValue):
            // A scoped set without -T resolves against the caller's focus chain (tmux
            // behavior); the CLI form requires -T because it has no focus to fall back on.
            var resolvedTarget = explicitTarget
            if resolvedTarget == nil {
                switch scope {
                case "workspace": resolvedTarget = target.workspace?.id.uuidString
                case "session": resolvedTarget = target.session?.id.uuidString
                case "tab": resolvedTarget = target.tab?.id.uuidString
                case "pane": resolvedTarget = target.paneID?.uuidString
                default: break
                }
            }
            guard scope == "global" || resolvedTarget != nil else { return .unresolved }
            return .requests([.setOption(scope: scope, target: resolvedTarget, key: key, rawValue: rawValue)])

        case let .setEnvironment(global, key, value):
            // tmux default scope is the focused session; -g writes the global table.
            let sessionID = global ? nil : target.session?.id
            guard global || sessionID != nil else { return .unresolved }
            return .requests([.setEnvironment(sessionID: sessionID, key: key, value: value)])

        case let .setBuffer(name, text):
            return .requests([.setBuffer(name: name, data: Data(text.utf8))])

        case let .pasteBuffer(name):
            guard let pane = target.paneID, let surface = target.surfaceID(of: pane) else { return .unresolved }
            return .requests([.pasteBuffer(surfaceID: surface, name: name, bracketed: true)])

        case let .deleteBuffer(name):
            return .requests([.deleteBuffer(name: name)])

        case let .setHook(event, source, condition):
            return .requests([.bindHook(event: event, source: source, condition: condition)])

        case let .unbindHook(id):
            return .requests([.unbindHook(id: id)])

        case let .respawnWindow(keepHistory):
            // Every pane in the focused (or `-t`-resolved) window, one respawn each.
            guard let tab = target.tab else { return .unresolved }
            let surfaces = tab.rootPane.allSurfaceIDs().map(\.uuidString)
            guard !surfaces.isEmpty else { return .unresolved }
            return .requests(surfaces.map { .respawnPane(surfaceID: $0, keepHistory: keepHistory) })

        // Show verbs produce OUTPUT — each front-end queries the daemon and renders
        // through its own surface (GUI message, compositor status flash, control-mode
        // lines). The daemon's hook executor logs them as no-ops.
        case .showOptions, .showEnvironment, .listBuffers, .showBuffer, .showHooks,
             .showMessages, .refreshClient:
            return .clientLocal(command)

        case let .findWindow(pattern, name, content, title, scopeTarget):
            // Content matching needs a live capture (client-side concern) — hand off (the
            // client applies the same `-t` scope). Name/title resolve from the snapshot here
            // so every front-end agrees.
            if content { return .clientLocal(command) }
            let matches = FindWindowMatcher.snapshotMatches(
                target.snapshot, pattern: pattern, name: name, title: title,
                target: scopeTarget, current: target.session)
            guard let first = matches.first else { return .unresolved }
            // tmux lists multiple matches; Harness focuses the first in snapshot order.
            return .requests([.selectTab(workspaceID: first.workspaceID, tabID: first.tabID)])

        // MARK: Pane structure
        case let .splitWindow(direction):
            guard let tab = target.tab, let pane = target.paneID else { return .unresolved }
            return .requests([.newSplit(tabID: tab.id, paneID: pane, direction: layoutDirection(for: direction))])

        case .killPane:
            guard let pane = target.paneID else { return .unresolved }
            return .requests([.killPane(paneID: pane)])

        case .zoomPane:
            guard let pane = target.paneID else { return .unresolved }
            return .requests([.zoomPane(paneID: pane)])

        case .breakPane:
            guard let pane = target.paneID else { return .unresolved }
            return .requests([.breakPane(paneID: pane)])

        case let .respawnPane(keepHistory):
            guard let pane = target.paneID, let surface = target.surfaceID(of: pane) else { return .unresolved }
            return .requests([.respawnPane(surfaceID: surface, keepHistory: keepHistory)])
        case .clearHistory:
            guard let pane = target.paneID, let surface = target.surfaceID(of: pane) else { return .unresolved }
            return .requests([.clearHistory(surfaceID: surface)])

        case let .resizePane(direction, amount):
            guard let pane = target.paneID else { return .unresolved }
            return .requests([.resizePane(paneID: pane, direction: direction, amount: amount)])

        case let .selectPane(paneTarget):
            return selectPane(paneTarget, target: target)

        case let .swapPane(paneTarget, source):
            // `-s X` swaps X with the destination; no `-s` swaps the caller's pane.
            // Relative destinations stay relative to the caller's focus (tmux).
            guard let src = swapSource(source, target: target, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex),
                  let current = target.paneID else { return .unresolved }
            let neighbor: PaneID?
            switch paneTarget {
            case .current: neighbor = current
            case .next, .right, .down: neighbor = target.pane(offset: 1)
            case .previous, .left, .up: neighbor = target.pane(offset: -1)
            case .last: neighbor = target.tab?.lastActivePaneID
            }
            guard let dst = neighbor, dst != src else { return .unresolved }
            return .requests([.swapPanes(srcPaneID: src, dstPaneID: dst)])

        case let .joinPane(direction):
            guard let dst = target.paneID, let src = target.markedPaneID, src != dst else { return .unresolved }
            return .requests([.joinPane(sourcePaneID: src, destPaneID: dst, direction: layoutDirection(for: direction))])

        case let .movePane(direction, source):
            // move-pane = join-pane with an explicit `-s` source (the daemon op is
            // identical). Resolve the source pane against the same snapshot — strictly,
            // so a mistyped `-s` never silently moves the focused pane.
            guard let srcTarget = target.resolving(
                source, command: .killPane, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex
            ), let src = srcTarget.paneID, let dst = target.paneID, src != dst else { return .unresolved }
            return .requests([.joinPane(sourcePaneID: src, destPaneID: dst, direction: layoutDirection(for: direction))])

        case .renumberWindows:
            guard let session = target.session else { return .unresolved }
            return .requests([.renumberWindows(sessionID: session.id)])

        case let .rotateWindow(forward):
            guard let tab = target.tab else { return .unresolved }
            return .requests([.rotatePanes(tabID: tab.id, forward: forward)])

        // MARK: Layouts
        case let .selectLayout(name):
            guard let tab = target.tab else { return .unresolved }
            return .requests([.applyLayout(tabID: tab.id, layout: name, mainPaneID: target.paneID)])

        case .nextLayout:
            guard let tab = target.tab else { return .unresolved }
            return .requests([.nextLayout(tabID: tab.id)])

        case .previousLayout:
            guard let tab = target.tab else { return .unresolved }
            return .requests([.previousLayout(tabID: tab.id)])

        // MARK: Tabs / windows
        case .newWindow:
            guard let ws = target.workspace else { return .unresolved }
            return .requests([.newTab(workspaceID: ws.id, cwd: nil)])

        case .killWindow:
            guard let tab = target.tab else { return .unresolved }
            return .requests([.closeTab(tabID: tab.id)])

        case let .renameWindow(newName):
            guard let newName, let tab = target.tab else {
                // Interactive rename has no headless form — let the client prompt.
                return .clientLocal(command)
            }
            return .requests([.renameTab(tabID: tab.id, name: newName)])

        case .nextWindow:
            return adjacentTab(target: target, delta: 1)

        case .previousWindow:
            return adjacentTab(target: target, delta: -1)

        case let .selectWindow(index):
            let pos = index - baseIndex
            guard let ws = target.workspace, let session = target.session,
                  pos >= 0, pos < session.tabs.count else { return .unresolved }
            return .requests([.selectTab(workspaceID: ws.id, tabID: session.tabs[pos].id)])

        case let .moveWindow(index):
            // Honor base-index like .selectWindow: `-t :N` is a window NUMBER, not a 0-based array
            // position. reorderTab clamps, so a negative is safe. (Without this, move-window lands
            // one slot off select-window under `base-index 1`.)
            guard let ws = target.workspace, let tab = target.tab else { return .unresolved }
            return .requests([.reorderTab(workspaceID: ws.id, tabID: tab.id, toIndex: index - baseIndex)])

        case let .swapWindow(index):
            // Same base-index correction; swapTab guards out-of-range (incl. negative) and no-ops.
            guard let ws = target.workspace, let tab = target.tab else { return .unresolved }
            return .requests([.swapTab(workspaceID: ws.id, tabID: tab.id, withIndex: index - baseIndex)])

        // MARK: Sessions / workspaces
        case let .newSession(name):
            guard let ws = target.workspace else { return .unresolved }
            return .requests([.newSession(workspaceID: ws.id, cwd: nil, name: name)])

        case .killSession:
            guard let session = target.session else { return .unresolved }
            return .requests([.closeSession(sessionID: session.id)])

        case let .renameSession(newName):
            guard let newName, let session = target.session else { return .clientLocal(command) }
            return .requests([.renameSession(sessionID: session.id, name: newName)])

        case .nextSession:
            return adjacentSession(target: target, delta: 1)

        case .previousSession:
            return adjacentSession(target: target, delta: -1)

        case let .selectSession(index):
            guard let ws = target.workspace, index >= 0, index < ws.sessions.count else { return .unresolved }
            return .requests([.selectSession(workspaceID: ws.id, sessionID: ws.sessions[index].id)])

        case let .selectWorkspace(index):
            let workspaces = target.snapshot.workspaces
            guard index >= 0, index < workspaces.count else { return .unresolved }
            return .requests([.selectWorkspace(id: workspaces[index].id)])

        case .nextWorkspace:
            return adjacentWorkspace(target: target, delta: 1)

        case .previousWorkspace:
            return adjacentWorkspace(target: target, delta: -1)

        // MARK: Scripting
        case let .sendKeys(keys):
            guard let pane = target.paneID, let surface = target.surfaceID(of: pane) else { return .unresolved }
            return .requests([.sendKeys(surfaceID: surface, keys: keys)])
        case let .sendKeysLiteral(text):
            // Literal text is sent verbatim — no key-token interpretation — via the raw byte path.
            guard let pane = target.paneID, let surface = target.surfaceID(of: pane) else { return .unresolved }
            return .requests([.sendData(surfaceID: surface, data: Data(text.utf8))])
        case let .sendKeysHex(hex):
            // Hex tokens (`1b`, `0x5b`, `41`) → raw bytes. Non-hex tokens are skipped.
            guard let pane = target.paneID, let surface = target.surfaceID(of: pane) else { return .unresolved }
            let bytes = hex.compactMap { tok -> UInt8? in
                let t = tok.hasPrefix("0x") || tok.hasPrefix("0X") ? String(tok.dropFirst(2)) : tok
                return UInt8(t, radix: 16)
            }
            return .requests([.sendData(surfaceID: surface, data: Data(bytes))])

        // MARK: Phase 6/7 — verbs that resolve to IPC
        case .lastWindow:
            guard let ws = target.workspace, let session = target.session,
                  let last = session.lastActiveTabID,
                  session.tabs.contains(where: { $0.id == last })
            else { return .unresolved }
            return .requests([.selectTab(workspaceID: ws.id, tabID: last)])

        case let .pipePane(shellCommand):
            guard let pane = target.paneID, let surface = target.surfaceID(of: pane) else { return .unresolved }
            return .requests([.pipePane(surfaceID: surface, shellCommand: shellCommand)])

        case let .linkWindow(targetSessionName):
            guard let tab = target.tab else { return .unresolved }
            let match = target.snapshot.workspaces.flatMap { $0.sessions }.first {
                $0.name == targetSessionName || $0.id.uuidString == targetSessionName
            }
            guard let session = match else { return .unresolved }
            return .requests([.linkWindow(tabID: tab.id, targetSessionID: session.id)])

        case .unlinkWindow:
            guard let tab = target.tab else { return .unresolved }
            return .requests([.unlinkWindow(tabID: tab.id)])

        // MARK: Client-local (UI overlays, modes, file/shell, composition)
        case .markPane, .synchronizePanes, .displayPanes, .copyMode, .copyModeCommand, .detachClient,
             .reattachSurface, .jumpToPreviousPrompt, .jumpToNextPrompt, .selectLastCommandOutput,
             .displayMessage, .displayMessagePrint, .runShell, .ifShell, .bindKey, .unbindKey, .listKeys,
             .sourceConfig, .reloadKeybindings, .showCheatsheet, .sequence,
             .sendPrefix, .sourceFile, .commandPrompt, .confirmBefore, .choose,
             .lockClient, .clockMode, .switchClientTable, .displayPopup, .displayMenu:
            return .clientLocal(command)
        }
    }

    // MARK: Helpers

    /// `-s` source pane for swap-pane: nil spec = the caller's active pane; a spec
    /// that doesn't resolve returns nil so the verb fails loudly upstream.
    private static func swapSource(
        _ source: TargetSpec?,
        target: CommandTarget,
        baseIndex: Int,
        paneBaseIndex: Int
    ) -> PaneID? {
        guard let source else { return target.paneID }
        guard let resolved = target.resolving(
            source, command: .killPane, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex
        ) else { return nil }
        return resolved.paneID
    }

    private static func selectPane(_ paneTarget: Command.PaneTarget, target: CommandTarget) -> CommandTranslation {
        guard let tab = target.tab, let current = target.paneID else { return .unresolved }
        switch paneTarget {
        case .current:
            return .requests([.selectPane(tabID: tab.id, paneID: current)])
        case .next:
            guard let dst = target.pane(offset: 1) else { return .unresolved }
            return .requests([.selectPane(tabID: tab.id, paneID: dst)])
        case .previous:
            guard let dst = target.pane(offset: -1) else { return .unresolved }
            return .requests([.selectPane(tabID: tab.id, paneID: dst)])
        case .last:
            guard let dst = tab.lastActivePaneID ?? target.pane(offset: 1) else { return .unresolved }
            return .requests([.selectPane(tabID: tab.id, paneID: dst)])
        case .left, .right, .up, .down:
            let axis: DirectionalAxis
            switch paneTarget {
            case .left: axis = .left
            case .right: axis = .right
            case .up: axis = .up
            default: axis = .down
            }
            // The daemon computes the neighbor and persists focus server-side.
            return .requests([.selectPaneDirectional(currentPaneID: current, direction: axis)])
        }
    }

    private static func adjacentTab(target: CommandTarget, delta: Int) -> CommandTranslation {
        guard let ws = target.workspace, let session = target.session, !session.tabs.isEmpty,
              let tab = target.tab, let idx = session.tabs.firstIndex(where: { $0.id == tab.id })
        else { return .unresolved }
        let next = ((idx + delta) % session.tabs.count + session.tabs.count) % session.tabs.count
        guard session.tabs[next].id != tab.id else { return .unresolved }
        return .requests([.selectTab(workspaceID: ws.id, tabID: session.tabs[next].id)])
    }

    private static func adjacentWorkspace(target: CommandTarget, delta: Int) -> CommandTranslation {
        let workspaces = target.snapshot.workspaces
        guard !workspaces.isEmpty,
              let currentID = target.snapshot.activeWorkspaceID,
              let idx = workspaces.firstIndex(where: { $0.id == currentID })
        else { return .unresolved }
        let next = ((idx + delta) % workspaces.count + workspaces.count) % workspaces.count
        return .requests([.selectWorkspace(id: workspaces[next].id)])
    }

    private static func adjacentSession(target: CommandTarget, delta: Int) -> CommandTranslation {
        guard let ws = target.workspace, !ws.sessions.isEmpty,
              let session = target.session,
              let idx = ws.sessions.firstIndex(where: { $0.id == session.id })
        else { return .unresolved }
        let next = ((idx + delta) % ws.sessions.count + ws.sessions.count) % ws.sessions.count
        guard ws.sessions[next].id != session.id else { return .unresolved }
        return .requests([.selectSession(workspaceID: ws.id, sessionID: ws.sessions[next].id)])
    }
}
