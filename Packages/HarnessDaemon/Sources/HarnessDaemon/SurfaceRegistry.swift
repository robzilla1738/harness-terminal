import Foundation
import HarnessCore

/// Single source of truth for Harness session layout and notifications.
/// @unchecked Sendable: all access to `sessions` and `editor` is serialized by `lock`.
public final class SurfaceRegistry: @unchecked Sendable {
    private var sessions: [DaemonSurfaceID: RealPty] = [:]
    private var editor = SessionEditor()
    private let store = SessionStore()
    private let lock = NSLock()
    private let bufferStore = PasteBufferStore()
    public let optionStore = OptionStore()
    public let environmentStore = EnvironmentStore()
    public let hookRegistry = HookRegistry()
    /// Hooks fire fire-and-forget here, never under `lock`, so a hook-bound command
    /// can re-enter `handle` (which locks) without deadlocking. Serial so hook
    /// reactions run in the order their events occurred.
    private let hookQueue = DispatchQueue(label: "com.robert.harness.hooks")
    private var hookExecutor: DaemonCommandExecutor?
    /// Invoked after every layout commit with the new revision. `DaemonServer` uses
    /// this to push `snapshotChanged` to snapshot subscribers (the compositor).
    public var onSnapshotCommitted: ((Int) -> Void)?

    // MARK: Monitoring (Phase 5)
    /// Cheap per-surface output state, updated on the PTY read thread and drained by
    /// `processMonitors` on a timer. Kept off `lock` (its own tiny lock) so the hot output
    /// path never contends with layout mutations.
    private struct SurfaceMonitor { var sawOutput = false; var sawBell = false; var lastOutput = Date() }
    private var monitors: [String: SurfaceMonitor] = [:]
    private let monitorLock = NSLock()
    private var monitorTimer: DispatchSourceTimer?

    public init() {
        editor.snapshot = store.load()
        if editor.snapshot.workspaces.isEmpty {
            editor.snapshot = SessionSnapshot()
            try? store.saveImmediately(editor.snapshot)
        }
        ensureAllSnapshotSurfaces()
        // Wire hook execution: bound commands run server-side via the registry's own
        // handlers. `fire` invokes this on `hookQueue` (off-lock), so re-entering
        // `handle` here is safe.
        let executor = DaemonCommandExecutor(registry: self)
        hookExecutor = executor
        hookRegistry.setExecutor { command, context in
            executor.execute(command, context: context)
        }
        startMonitorTimer()
    }

    // MARK: - Output monitoring (activity / silence / bell)

    private func startMonitorTimer() {
        let timer = DispatchSource.makeTimerSource(queue: hookQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.processMonitors() }
        timer.resume()
        monitorTimer = timer
    }

    /// Record output for a surface — runs on the PTY read thread, so it must stay cheap
    /// (no `lock`, no snapshot walk): just flag output / bell and stamp the time.
    private func noteSurfaceOutput(surfaceKey: String, data: Data) {
        let bell = data.contains(0x07)
        monitorLock.lock()
        var m = monitors[surfaceKey] ?? SurfaceMonitor()
        m.sawOutput = true
        m.lastOutput = Date()
        if bell { m.sawBell = true }
        monitors[surfaceKey] = m
        monitorLock.unlock()
    }

    /// Drain the monitor state (timer) and raise activity/silence/bell alerts on non-current
    /// windows, gated on the matching option. Sets the tab flag (surfaced as `#`/`~`/`!` in
    /// `#{window_flags}`) and fires the hook — both only on a real transition.
    private func processMonitors() {
        monitorLock.lock()
        let now = Date()
        var drained: [String: (sawOutput: Bool, sawBell: Bool, idle: TimeInterval)] = [:]
        for (key, m) in monitors {
            drained[key] = (m.sawOutput, m.sawBell, now.timeIntervalSince(m.lastOutput))
            monitors[key]?.sawOutput = false
            monitors[key]?.sawBell = false
        }
        monitorLock.unlock()
        guard !drained.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        let wantActivity = optionStore.get("monitor-activity")?.boolValue ?? false
        let wantBell = optionStore.get("monitor-bell")?.boolValue ?? true
        let silenceSeconds = optionStore.get("monitor-silence")?.intValue ?? 0
        // The orphan sweep runs even when every monitor option is off, so dead-surface keys never
        // accumulate; only the alert processing below is gated on the options being enabled.
        let monitoring = wantActivity || wantBell || silenceSeconds > 0
        var changed = false
        var fired: [(HookEvent, String)] = []
        var orphans: [String] = []
        for (key, st) in drained {
            guard let match = editor.tab(forSurfaceKey: key) else {
                // Output for a surface with no tab — an in-flight PTY read raced `closeSurfaces`
                // and re-created the monitor entry after teardown. Evict it so `monitors` can't
                // grow unbounded with dead-surface keys that nothing will ever clean.
                orphans.append(key)
                continue
            }
            guard monitoring,
                  !editor.tabIsCurrent(workspaceID: match.workspaceID, tabID: match.tabID) else { continue }
            if wantActivity, st.sawOutput,
               editor.setTabAlerts(workspaceID: match.workspaceID, tabID: match.tabID, activity: true) {
                changed = true; fired.append((.paneActivity, key))
            }
            if wantBell, st.sawBell,
               editor.setTabAlerts(workspaceID: match.workspaceID, tabID: match.tabID, bell: true) {
                changed = true; fired.append((.paneBell, key))
            }
            if silenceSeconds > 0, !st.sawOutput, st.idle >= Double(silenceSeconds),
               editor.setTabAlerts(workspaceID: match.workspaceID, tabID: match.tabID, silence: true) {
                changed = true; fired.append((.paneSilence, key))
            }
        }
        if changed { commit() }
        for (event, key) in fired { fireHookLocked(event, surfaceKey: key) }
        if !orphans.isEmpty {
            monitorLock.lock()
            for key in orphans { monitors.removeValue(forKey: key) }
            monitorLock.unlock()
        }
    }

    public var snapshot: SessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return editor.snapshot
    }

    /// Aggregate counts for `daemon-stats`. Returned in a single locked read so
    /// the values are mutually consistent.
    public var surfaceTelemetry: (surfaceCount: Int, scrollbackBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let count = sessions.count
        let bytes = sessions.values.reduce(0) { $0 + $1.scrollbackByteCount }
        return (count, bytes)
    }

    public func handle(_ request: IPCRequest) -> IPCResponse {
        lock.lock()
        defer { lock.unlock() }
        switch request {
        case .ping:
            return .pong
        case .listWorkspaces:
            return .workspaces(editor.snapshot.workspaces.map {
                WorkspaceSummary(id: $0.id, name: $0.name, tabCount: $0.sessions.count)
            })
        case .listSurfaces:
            return .surfaces(editor.listSurfaces())
        case .listAgents:
            return .agents(editor.listAgents())
        case let .newWorkspace(name):
            let id = editor.addWorkspace(name: name)
            commit()
            return .workspaceID(id)
        case let .newSession(workspaceID, cwd, name):
            guard let sessionID = editor.addSession(to: workspaceID, cwd: cwd, name: name) else {
                return .error("Workspace not found")
            }
            ensureSessionSurfaces(sessionID: sessionID)
            commit()
            fireHookLocked(.afterNewSession)
            return .sessionID(sessionID)
        case let .newTab(workspaceID, cwd):
            guard let tabID = editor.addTab(to: workspaceID, cwd: cwd) else {
                return .error("Workspace not found")
            }
            ensureTabSurfaces(tabID: tabID)
            commit()
            fireHookLocked(.afterNewTab)
            return .tabID(tabID)
        case let .newTabInWorkspace(named, cwd):
            guard let workspaceID = editor.resolveWorkspaceID(nameOrID: named) else {
                return .error("Workspace not found: \(named)")
            }
            guard let tabID = editor.addTab(to: workspaceID, cwd: cwd) else {
                return .error("Could not create tab")
            }
            ensureTabSurfaces(tabID: tabID)
            commit()
            fireHookLocked(.afterNewTab)
            return .tabID(tabID)
        case let .newSplit(tabID, paneID, direction):
            guard let workspace = editor.snapshot.workspaces.first(where: { ws in
                ws.sessions.contains { session in session.tabs.contains { $0.id == tabID } }
            }) else { return .error("Tab not found") }
            let tab = workspace.sessions.flatMap { $0.tabs }.first { $0.id == tabID }
            // Target-less split focuses the tab's active pane (falling back to its
            // first leaf), matching tmux's "split the current pane".
            let targetPane = paneID ?? tab?.activePaneID ?? tab?.rootPane.allPaneIDs().first
            guard let paneID = targetPane,
                  let newPaneID = editor.splitPane(
                      in: workspace.id,
                      tabID: tabID,
                      paneID: paneID,
                      direction: direction
                  )
            else { return .error("Could not split pane") }
            if let surfaceID = editor.surfaceID(forPaneID: newPaneID) {
                let cwd = editor.snapshot.workspaces
                    .flatMap { workspace in workspace.sessions.flatMap { $0.tabs } }
                    .first(where: { $0.id == tabID })?
                    .cwd
                _ = createOrEnsureSurface(
                    surfaceID: surfaceID.uuidString,
                    cwd: cwd,
                    shell: nil,
                    rows: 24,
                    cols: 80,
                    scrollbackBytes: nil
                )
            }
            commit()
            fireHookLocked(.afterSplitPane, surfaceKey: editor.surfaceID(forPaneID: newPaneID)?.uuidString)
            return .paneID(newPaneID)
        case let .selectWorkspace(id):
            guard editor.selectWorkspace(id) else { return .error("Workspace not found") }
            commit()
            return .ok
        case let .selectWorkspaceByName(name):
            guard let id = editor.resolveWorkspaceID(nameOrID: name) else {
                return .error("Workspace not found: \(name)")
            }
            guard editor.selectWorkspace(id) else { return .error("Workspace not found: \(name)") }
            commit()
            return .workspaceID(id)
        case let .selectSession(workspaceID, sessionID):
            guard editor.selectSession(workspaceID: workspaceID, sessionID: sessionID) else {
                return .error("Session not found")
            }
            commit()
            return .ok
        case let .selectTab(workspaceID, tabID):
            guard editor.selectTab(workspaceID: workspaceID, tabID: tabID) else {
                return .error("Tab not found")
            }
            commit()
            return .ok
        case let .reorderTab(workspaceID, tabID, toIndex):
            guard editor.reorderTab(workspaceID: workspaceID, tabID: tabID, toIndex: toIndex) else {
                return .error("Tab not found")
            }
            commit()
            return .ok
        case let .swapTab(workspaceID, tabID, withIndex):
            guard editor.swapTab(workspaceID: workspaceID, tabID: tabID, withIndex: withIndex) else {
                return .error("Tab not found")
            }
            commit()
            return .ok
        case let .reorderSession(workspaceID, sessionID, toIndex):
            guard editor.reorderSession(workspaceID: workspaceID, sessionID: sessionID, toIndex: toIndex) else {
                return .error("Session not found")
            }
            commit()
            return .ok
        case let .renumberWindows(sessionID):
            guard editor.renumberWindows(sessionID: sessionID) else {
                return .error("Session not found")
            }
            commit()
            return .ok
        case let .closeTab(tabID):
            let owningSession = editor.snapshot.workspaces
                .flatMap(\.sessions)
                .first(where: { $0.tabs.contains { $0.id == tabID } })?.id
            let closedSurfaces = editor.snapshot.workspaces
                .flatMap { workspace in workspace.sessions.flatMap { $0.tabs } }
                .first(where: { $0.id == tabID })?
                .rootPane
                .allSurfaceIDs()
                .map(\.uuidString) ?? []
            guard editor.closeTab(tabID) else { return .error("Tab not found") }
            closeSurfaces(closedSurfaces)
            ensureAllSnapshotSurfaces()
            // tmux `renumber-windows`: keep indices contiguous after a tab closes.
            if optionStore.get("renumber-windows")?.boolValue == true, let owningSession {
                _ = editor.renumberWindows(sessionID: owningSession)
            }
            commit()
            fireHookLocked(.afterKillTab)
            return .ok
        case let .closeSession(sessionID):
            let closedSurfaces = editor.snapshot.workspaces
                .flatMap(\.sessions)
                .first(where: { $0.id == sessionID })?
                .tabs
                .flatMap { $0.rootPane.allSurfaceIDs().map(\.uuidString) } ?? []
            guard editor.closeSession(sessionID) else { return .error("Session not found") }
            closeSurfaces(closedSurfaces)
            ensureAllSnapshotSurfaces()
            commit()
            return .ok
        case let .closeWorkspace(id):
            let closedSurfaces = editor.snapshot.workspaces
                .first(where: { $0.id == id })?
                .sessions
                .flatMap { $0.tabs }
                .flatMap { $0.rootPane.allSurfaceIDs().map(\.uuidString) } ?? []
            guard editor.closeWorkspace(id) else { return .error("Cannot close workspace") }
            closeSurfaces(closedSurfaces)
            commit()
            return .ok
        case let .setTheme(name):
            editor.setTheme(name)
            commit()
            return .ok
        case let .setKeepSessionsOnQuit(value):
            editor.setKeepSessionsOnQuit(value)
            commit()
            return .ok
        case let .setSessionPersistent(sessionID, persistent):
            guard editor.setSessionPersistent(sessionID, persistent) else {
                return .error("Session not found")
            }
            commit()
            return .ok
        case .closeEphemeralSessions:
            // Close each ephemeral session inline (NOT via re-entrant handle(.closeSession),
            // which would deadlock on the non-recursive `lock` we already hold). Same helpers
            // the .closeSession case uses, so PTYs are killed and the layout stays consistent.
            let ids = editor.ephemeralSessionIDs()
            guard !ids.isEmpty else { return .ok }
            for sessionID in ids {
                let closedSurfaces = editor.snapshot.workspaces
                    .flatMap(\.sessions)
                    .first(where: { $0.id == sessionID })?
                    .tabs
                    .flatMap { $0.rootPane.allSurfaceIDs().map(\.uuidString) } ?? []
                guard editor.closeSession(sessionID) else { continue }
                closeSurfaces(closedSurfaces)
            }
            ensureAllSnapshotSurfaces()
            commit()
            return .ok
        case let .send(surfaceID, text):
            guard let session = sessions[surfaceID] else {
                return .error("Surface not found")
            }
            session.write(text)
            return .ok
        case let .sendData(surfaceID, data):
            guard let session = sessions[surfaceID] else {
                return .error("Surface not found")
            }
            session.write(data)
            return .ok
        case let .notify(surfaceID, title, body):
            let notification = AgentNotification(
                surfaceID: UUID(uuidString: surfaceID),
                daemonSurfaceID: surfaceID,
                title: title,
                body: body
            )
            NotificationBus.shared.post(notification)
            markWaiting(surfaceKey: surfaceID, text: body)
            commit()
            fireHookLocked(.notificationPosted, surfaceKey: surfaceID)
            return .ok
        case let .clearNotification(surfaceID):
            if let uuid = UUID(uuidString: surfaceID) {
                editor.clearTabNotification(surfaceID: uuid)
            }
            commit()
            return .ok
        case let .updateTabTitle(surfaceID, title):
            // OSC/program-driven rename. Honor `allow-rename` (global) and the
            // per-tab `automatic-rename` flag — a manual `rename-tab` turns the
            // latter off so the chosen name sticks (tmux semantics).
            if let uuid = UUID(uuidString: surfaceID),
               optionStore.get("allow-rename")?.boolValue ?? true,
               automaticRenameEnabled(forSurfaceKey: surfaceID) {
                editor.updateTabTitle(surfaceID: uuid, title: title)
                commit()
            }
            return .ok
        case let .updateTabCwd(surfaceID, path):
            if let uuid = UUID(uuidString: surfaceID) {
                editor.updateTabCwd(surfaceID: uuid, path: path)
                commit()
            }
            return .ok
        case let .updateTabGitBranch(workspaceID, tabID, branch):
            editor.updateTabMetadata(workspaceID: workspaceID, tabID: tabID, gitBranch: branch, cwd: nil)
            commit()
            return .ok
        case .getSnapshot:
            return .snapshot(editor.snapshot)
        case let .createSurface(cwd, shell):
            let surfaceID = UUID().uuidString
            return createOrEnsureSurface(
                surfaceID: surfaceID,
                cwd: cwd,
                shell: shell,
                rows: 24,
                cols: 80,
                scrollbackBytes: nil
            ).map { .surfaceID($0) } ?? .error("Failed to launch shell")
        case let .ensureSurface(surfaceID, cwd, shell, rows, cols, scrollbackBytes):
            return createOrEnsureSurface(
                surfaceID: surfaceID,
                cwd: cwd,
                shell: shell,
                rows: rows,
                cols: cols,
                scrollbackBytes: scrollbackBytes
            ).map { _ in .ok } ?? .error("Failed to launch shell")
        case .attachSurface:
            return .ok
        case let .sendKeys(surfaceID, keys):
            let bytes = KeyTokenParser.encode(keys: keys)
            if let session = sessions[surfaceID] {
                session.write(bytes)
                return .ok
            }
            return .error("Surface not found")
        case let .capturePane(surfaceID, includeScrollback):
            if let session = sessions[surfaceID] {
                let text = session.captureScrollback(includeHistory: includeScrollback)
                return .text(text)
            }
            return .error("Surface not found")
        case let .closeSurface(surfaceID):
            closeSurfaces([surfaceID])
            return .ok
        case let .capturePaneRange(surfaceID, start, end, escapeSequences, joinWrapped):
            guard let session = sessions[surfaceID] else { return .error("Surface not found") }
            // `-e` keeps the program's original escapes (raw byte stream); plain capture
            // reconstructs the actual on-screen grid, with `-J` joining soft-wrapped rows.
            if escapeSequences {
                return .text(session.captureRange(start: start, end: end, escapeSequences: true))
            }
            return .text(session.captureGrid(start: start, end: end, joinWrapped: joinWrapped))
        case let .pipePane(surfaceID, shellCommand):
            guard sessions[surfaceID] != nil else { return .error("Surface not found") }
            if let shellCommand, !shellCommand.isEmpty {
                startPipe(surfaceID: surfaceID, shellCommand: shellCommand)
            } else {
                stopPipe(surfaceID: surfaceID)
            }
            return .ok
        case let .linkWindow(tabID, targetSessionID):
            guard let newTabID = editor.linkWindow(tabID, toSessionID: targetSessionID) else {
                return .error("Could not link window (tab or target session not found)")
            }
            ensureAllSnapshotSurfaces()
            commit()
            return .tabID(newTabID)
        case let .unlinkWindow(tabID):
            let removed = editor.snapshot.workspaces
                .flatMap { $0.sessions }.flatMap { $0.tabs }
                .first(where: { $0.id == tabID })?
                .rootPane.allSurfaceIDs().map(\.uuidString) ?? []
            guard editor.unlinkWindow(tabID) else { return .error("Window is not linked") }
            closeSurfaces(removed)   // ref-counted: shared surfaces survive
            commit()
            return .ok
        case let .killPane(paneID):
            let killedSurfaceID = editor.surfaceID(forPaneID: paneID)?.uuidString
            guard editor.killPane(paneID) else { return .error("Pane not found") }
            if let killedSurfaceID { closeSurfaces([killedSurfaceID]) }
            commit()
            fireHookLocked(.afterKillPane, surfaceKey: killedSurfaceID)
            return .ok
        case let .swapPanes(srcID, dstID):
            guard editor.swapPanes(srcID, dstID) else { return .error("Panes not found") }
            commit()
            return .ok
        case let .resizePane(paneID, direction, amount):
            guard editor.resizePane(paneID, direction: direction, amount: amount) else {
                return .error("Pane not found")
            }
            commit()
            fireHookLocked(.afterResizePane, surfaceKey: editor.surfaceID(forPaneID: paneID)?.uuidString)
            return .ok
        case let .resizePaneRatio(tabID, firstPaneID, secondPaneID, ratio):
            guard editor.setSplitRatio(
                tabID: tabID,
                firstPaneID: firstPaneID,
                secondPaneID: secondPaneID,
                ratio: ratio
            ) else {
                return .error("Split not found")
            }
            commit()
            fireHookLocked(.afterResizePane)
            return .ok
        case let .zoomPane(paneID):
            guard editor.zoomPane(paneID) else { return .error("Pane not found") }
            commit()
            return .ok
        case let .setCopyMode(surfaceID, enabled):
            NotificationBus.shared.postCopyMode(surfaceID: surfaceID, enabled: enabled)
            return .ok
        case let .renameTab(tabID, name):
            guard editor.renameTab(tabID, name: name) else { return .error("Tab not found") }
            // A manual rename sticks: turn off automatic-rename for this tab so a
            // later OSC title doesn't clobber the chosen name.
            optionStore.set(.bool(false), key: "automatic-rename", scope: .tab, target: tabID.uuidString)
            commit()
            return .ok
        case let .renameSession(sessionID, name):
            guard editor.renameSession(sessionID, name: name) else { return .error("Session not found") }
            commit()
            return .ok
        case let .renameWorkspace(workspaceID, name):
            guard editor.renameWorkspace(workspaceID, name: name) else { return .error("Workspace not found") }
            commit()
            return .ok
        case let .detectAgent(surfaceID):
            return .agentInfo(AgentDetector.snapshot(forSurfaceKey: surfaceID))
        case let .subscribeSurfaceOutput(surfaceID, _):
            return subscribe(surfaceID: surfaceID)
        case .subscribeSnapshot:
            // FD-level streaming, owned by DaemonServer (intercepted before reaching
            // the registry); the stub keeps the switch exhaustive.
            return .error("subscribeSnapshot must be handled by DaemonServer")
        case .waitFor:
            // Socket-layer blocking primitive, owned by DaemonServer (intercepted before
            // the registry so it never blocks this lock); stub keeps the switch exhaustive.
            return .error("wait-for must be handled by DaemonServer")
        case let .cancelSubscription(surfaceID):
            sessions[surfaceID]?.cancelSubscription()
            return .ok
        case let .replayScrollback(surfaceID, fromSequence):
            guard let session = sessions[surfaceID] else { return .text("") }
            return .text(session.replay(fromSequence: fromSequence))
        case let .resizeSurface(surfaceID, rows, cols):
            sessions[surfaceID]?.resize(rows: rows, cols: cols)
            return .ok
        case .detachSurface:
            // Per-client detach is owned by DaemonServer, which knows *which* connection asked
            // and releases only that client's subscription + size vote. The registry can't see
            // the client, so the socket path is intercepted upstream; reaching here would mean a
            // caller bypassed the server — do nothing (the old code wiped *every* subscriber on
            // the surface via cancelSubscription(token: nil), which dropped other clients too).
            return .ok
        case .identifyClient, .listClients, .detachClient, .daemonStats:
            // Client lifecycle and aggregate stats are owned by the DaemonServer
            // layer (it tracks FDs). Server intercepts these before reaching the
            // registry; the stubs here exist only to keep the switch exhaustive.
            return .error("Client lifecycle requests must be handled by DaemonServer")
        case let .setBuffer(name, data):
            let final = bufferStore.set(data, name: name)
            return .text(final)
        case let .getBuffer(name):
            let buffer: PasteBufferStore.Buffer?
            if let name { buffer = bufferStore.get(name) }
            else { buffer = bufferStore.mostRecent() }
            guard let buffer else { return .error("Buffer not found") }
            return .buffer(BufferSummary(
                name: buffer.name,
                byteCount: buffer.data.count,
                preview: buffer.preview,
                createdAt: buffer.createdAt,
                data: buffer.data
            ))
        case .listBuffers:
            let summaries = bufferStore.list().map {
                BufferSummary(name: $0.name, byteCount: $0.data.count, preview: $0.preview, createdAt: $0.createdAt)
            }
            return .buffers(summaries)
        case let .deleteBuffer(name):
            return bufferStore.delete(name) ? .ok : .error("Buffer not found")
        case let .pasteBuffer(surfaceID, name, bracketed):
            guard let session = sessions[surfaceID] else { return .error("Surface not found") }
            let buffer: PasteBufferStore.Buffer?
            if let name { buffer = bufferStore.get(name) }
            else { buffer = bufferStore.mostRecent() }
            guard let buffer else { return .error("Buffer not found") }
            if bracketed {
                // tmux `paste-buffer -p`: wrap in bracketed-paste markers so the
                // program treats it as a single pasted block (DECSET 2004).
                var out = Data("\u{1b}[200~".utf8)
                out.append(buffer.data)
                out.append(Data("\u{1b}[201~".utf8))
                session.write(out)
            } else {
                session.write(buffer.data)
            }
            return .ok
        case let .selectPaneDirectional(currentPaneID, direction):
            let target: Command.PaneTarget
            switch direction {
            case .left: target = .left
            case .right: target = .right
            case .up: target = .up
            case .down: target = .down
            }
            guard let neighbor = editor.directionalNeighbor(of: currentPaneID, direction: target) else {
                return .error("No neighbor in that direction")
            }
            // Persist the new focus server-side so every client agrees on the active
            // pane (not just the caller). Best-effort: the neighbor is in the same tab.
            if let loc = editor.tab(containingPaneID: neighbor) {
                _ = editor.setActivePane(workspaceID: loc.workspaceID, tabID: loc.tabID, paneID: neighbor)
                commit()
            }
            return .paneID(neighbor)
        case let .selectPane(tabID, paneID):
            guard let loc = editor.tab(containingPaneID: paneID), loc.tabID == tabID else {
                return .error("Pane not found in tab")
            }
            guard editor.setActivePane(workspaceID: loc.workspaceID, tabID: tabID, paneID: paneID) else {
                return .error("Could not select pane")
            }
            commit()
            return .ok
        case let .applyLayout(tabID, layout, mainPaneID):
            guard let template = LayoutTemplate(rawValue: layout) else {
                return .error("Unknown layout: \(layout)")
            }
            guard editor.applyLayout(tabID: tabID, layout: template, mainPaneID: mainPaneID) else {
                return .error("Tab not found or has fewer than 2 panes")
            }
            commit()
            return .ok
        case let .nextLayout(tabID):
            // No per-tab "last layout" memory yet (lands in Phase 6 with the
            // option store); we cycle from `evenHorizontal` each call. That's
            // already a useful "give me a different layout" gesture.
            guard editor.applyLayout(tabID: tabID, layout: .evenHorizontal.next(), mainPaneID: nil) else {
                return .error("Tab not found")
            }
            commit()
            return .ok
        case let .previousLayout(tabID):
            guard editor.applyLayout(tabID: tabID, layout: .evenHorizontal.previous(), mainPaneID: nil) else {
                return .error("Tab not found")
            }
            commit()
            return .ok
        case let .rotatePanes(tabID, forward):
            guard editor.rotatePanes(tabID: tabID, forward: forward) else {
                return .error("Tab not found")
            }
            commit()
            return .ok
        case let .breakPane(paneID):
            guard let newTab = editor.breakPane(paneID: paneID) else {
                return .error("Cannot break pane (only pane in tab, or pane not found)")
            }
            commit()
            return .tabID(newTab)
        case let .joinPane(source, dest, direction):
            guard let newPane = editor.joinPane(sourcePaneID: source, destPaneID: dest, direction: direction) else {
                return .error("Cannot join pane")
            }
            commit()
            return .paneID(newPane)
        case let .respawnPane(surfaceID, keepHistory):
            guard let session = sessions[surfaceID] else { return .error("Surface not found") }
            session.respawn(clearHistory: !keepHistory)
            return .ok
        case let .setOption(scopeRaw, target, key, raw):
            guard let scope = OptionStore.Scope(rawValue: scopeRaw) else {
                return .error("Unknown option scope: \(scopeRaw)")
            }
            // The on-disk key joins scope:target:key with colons; a colon in the option name or
            // target would mis-parse on read-back. Option names and ID targets never contain one,
            // so reject it rather than silently corrupt the store.
            guard !key.contains(":"), !(target?.contains(":") ?? false) else {
                return .error("Option name/target must not contain ':'")
            }
            optionStore.set(.init(parsing: raw), key: key, scope: scope, target: target)
            // Nudge snapshot subscribers (the attach-window compositor) so a runtime option
            // change — status-*, mouse, pane-style, mode-keys — reaches attached clients instead
            // of being stuck at their startup values. Re-uses the snapshot push as a generic
            // "re-read server state" signal (revision unchanged; clients re-pull options).
            onSnapshotCommitted?(editor.snapshot.revision)
            return .ok
        case let .showOptions(scopeRaw):
            let scope = scopeRaw.flatMap(OptionStore.Scope.init(rawValue:))
            let entries = optionStore.snapshot(scope: scope).map { key, value in
                OptionEntry(scope: key.scope.rawValue, target: key.target, key: key.key, value: value.stringValue)
            }
            return .options(entries)
        case let .setEnvironment(sessionID, key, value):
            environmentStore.set(value, key: key, sessionID: sessionID?.uuidString)
            return .ok
        case let .showEnvironment(sessionID):
            let entries = environmentStore.entries(sessionID: sessionID?.uuidString).map { entry in
                OptionEntry(scope: entry.scope, target: sessionID?.uuidString, key: entry.key, value: entry.value)
            }
            return .options(entries)
        case let .bindHook(eventRaw, source, condition):
            guard let event = HookEvent(rawValue: eventRaw) else {
                return .error("Unknown hook event: \(eventRaw)")
            }
            do {
                let command = try CommandParser.parse(source)
                let id = hookRegistry.bind(event: event, command: command, conditionFormat: condition)
                return .hookID(id)
            } catch {
                return .error("Parse failed: \(error)")
            }
        case let .unbindHook(id):
            return hookRegistry.unbind(id: id) ? .ok : .error("Hook not found")
        case let .listHooks(eventRaw):
            let event = eventRaw.flatMap(HookEvent.init(rawValue:))
            let entries = hookRegistry.list(event: event).map {
                HookEntry(id: $0.id, event: $0.event.rawValue, commandSource: $0.command.shortDescription, condition: $0.conditionFormat)
            }
            return .hooks(entries)
        case let .displayMessage(format):
            // Render via FormatString using whatever context the daemon can
            // build right now (active workspace/tab from snapshot). UI clients
            // observe the notification bus and decide how to surface it.
            let context = buildFormatContext()
            let text = FormatString.evaluate(format, context: context)
            NotificationBus.shared.post(AgentNotification(
                surfaceID: nil,
                daemonSurfaceID: nil,
                title: "Harness",
                body: text
            ))
            return .ok
        }
    }

    private func subscribe(surfaceID: String) -> IPCResponse {
        // Real streaming lives on the daemon socket layer (DaemonServer); here
        // we just acknowledge so callers don't crash.
        return .ok
    }

    public func subscribe(
        surfaceID: String,
        handler: @escaping @Sendable (Data, UInt64) -> Void
    ) -> UUID? {
        lock.lock()
        let session = sessions[surfaceID]
        lock.unlock()
        return session?.subscribe(handler)
    }

    public func cancelSubscription(surfaceID: String, token: UUID) {
        lock.lock()
        let session = sessions[surfaceID]
        lock.unlock()
        session?.cancelSubscription(token: token)
    }

    public func applyAgentChanges(_ changes: [String: AgentSnapshot?]) {
        lock.lock()
        defer { lock.unlock() }
        // Fire agent-state-changed only on an actual activity transition, so a steady
        // "working" stream of scans doesn't spam the hook.
        var transitioned: [String] = []
        for (surfaceKey, snapshot) in changes {
            let before = agentActivityString(forSurfaceKey: surfaceKey)
            editor.setAgent(snapshot, forSurfaceKey: surfaceKey)
            if before != snapshot?.activity.rawValue { transitioned.append(surfaceKey) }
        }
        commit()
        for surfaceKey in transitioned { fireHookLocked(.agentStateChanged, surfaceKey: surfaceKey) }
    }

    /// Current agent activity (raw) for the tab backing `surfaceKey`, or nil. Caller
    /// must hold `lock`.
    private func agentActivityString(forSurfaceKey surfaceKey: String) -> String? {
        guard let match = editor.tab(forSurfaceKey: surfaceKey) else { return nil }
        return editor.snapshot.workspaces
            .first(where: { $0.id == match.workspaceID })?
            .sessions.flatMap { $0.tabs }
            .first(where: { $0.id == match.tabID })?
            .agent?.activity.rawValue
    }

    public func refreshSurfaceMetadata() {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for (surfaceKey, session) in sessions {
            guard let uuid = UUID(uuidString: surfaceKey),
                  let cwd = session.currentWorkingDirectory(),
                  let match = editor.tab(for: uuid)
            else { continue }
            let current = editor.snapshot.workspaces
                .first(where: { $0.id == match.workspaceID })?
                .sessions
                .flatMap { $0.tabs }
                .first(where: { $0.id == match.tabID })?
                .cwd
            guard current != cwd else { continue }
            editor.updateTabCwd(surfaceID: uuid, path: cwd)
            changed = true
        }
        if changed { commit() }
    }

    /// Build a `FormatContext` from the current snapshot's active selection.
    /// Used by `display-message` and hook firing. Conservative: nil fields
    /// stay nil so format strings render an empty token instead of "(none)".
    public func buildFormatContext(surfaceKey: String? = nil, clientName: String? = nil) -> FormatContext {
        // When the event names a specific surface (split/kill/exit), resolve THAT
        // pane's tab so tokens like #{pane_cwd} reflect the affected pane; otherwise
        // fall back to the active selection.
        let workspace = editor.snapshot.activeWorkspace
        let session = workspace?.activeSession
        var tab = workspace?.activeTab
        if let surfaceKey, let match = editor.tab(forSurfaceKey: surfaceKey) {
            let resolved = editor.snapshot.workspaces
                .first(where: { $0.id == match.workspaceID })?
                .sessions.flatMap { $0.tabs }
                .first(where: { $0.id == match.tabID })
            if let resolved { tab = resolved }
        }
        return FormatContext(
            paneID: surfaceKey,
            paneTitle: tab?.title,
            paneCwd: tab?.cwd,
            paneActive: surfaceKey != nil,
            paneIndex: nil,
            sessionName: session?.name.isEmpty == false ? session?.name : nil,
            tabName: tab?.title,
            tabIndex: session?.tabs.firstIndex(where: { $0.id == tab?.id }),
            workspaceName: workspace?.name,
            agentKind: tab?.agent?.kind.rawValue,
            agentActivity: tab?.agent?.activity.rawValue,
            gitBranch: tab?.gitBranch,
            clientName: clientName,
            windowFlags: tab.map { ($0.zoomedPaneID != nil ? "Z" : "") + $0.alertFlags }
        )
    }

    // MARK: - Hook firing

    /// Schedule the hooks bound to `event`. MUST be called with `lock` held: it reads
    /// the locked snapshot to build the context, then fires on `hookQueue` so the
    /// commands run after the current mutation commits and the lock is released.
    private func fireHookLocked(_ event: HookEvent, surfaceKey: String? = nil) {
        let context = buildFormatContext(surfaceKey: surfaceKey)
        hookQueue.async { [weak self] in self?.hookRegistry.fire(event, context: context) }
    }

    /// Client attach/detach originate in `DaemonServer` (which owns FDs), outside the
    /// registry lock — these acquire the lock to build a consistent context.
    public func fireClientAttached(label: String?) {
        lock.lock(); let context = buildFormatContext(clientName: label); lock.unlock()
        hookQueue.async { [weak self] in self?.hookRegistry.fire(.clientAttached, context: context) }
    }

    public func fireClientDetached(label: String?) {
        lock.lock(); let context = buildFormatContext(clientName: label); lock.unlock()
        hookQueue.async { [weak self] in self?.hookRegistry.fire(.clientDetached, context: context) }
    }

    // MARK: - Hook target resolution + shell execution

    /// Active-selection resolvers used by `DaemonCommandExecutor` for target-less hook
    /// commands. Best-effort first-leaf until Phase 2 adds a server-side active pane.
    func activeWorkspaceID() -> WorkspaceID? {
        lock.lock(); defer { lock.unlock() }
        return editor.snapshot.activeWorkspaceID
    }

    func activeTabID() -> TabID? {
        lock.lock(); defer { lock.unlock() }
        return editor.snapshot.activeWorkspace?.activeTab?.id
    }

    func activePaneID() -> PaneID? {
        lock.lock(); defer { lock.unlock() }
        return editor.snapshot.activeWorkspace?.activeTab?.rootPane.allPaneIDs().first
    }

    func activePaneSurfaceKey() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let pane = editor.snapshot.activeWorkspace?.activeTab?.rootPane.allPaneIDs().first else { return nil }
        return editor.surfaceID(forPaneID: pane)?.uuidString
    }

    /// Run `command` via `/bin/sh -c` for a `run-shell` hook. Async (fire-and-forget);
    /// when `captureToBuffer` is set, stdout is stored in a paste buffer on completion.
    func runShellForHook(_ command: String, captureToBuffer: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = captureToBuffer ? Pipe() : nil
        if let pipe { process.standardOutput = pipe }
        process.terminationHandler = { [weak self] _ in
            guard captureToBuffer, let pipe, let self else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if !data.isEmpty {
                _ = self.handle(.setBuffer(name: nil, data: data))
            }
        }
        do { try process.run() } catch {
            fputs("HarnessDaemon: run-shell hook failed: \(error)\n", stderr)
        }
    }

    /// Run `command` via `/bin/sh -c` synchronously and report exit-0 for `if-shell`.
    /// Called on `hookQueue`, never under the registry lock.
    func evaluateShellCondition(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func markWaiting(surfaceKey: String, text: String) {
        guard let match = editor.tab(forSurfaceKey: surfaceKey) else { return }
        editor.setTabStatus(
            workspaceID: match.workspaceID,
            tabID: match.tabID,
            status: .waiting,
            notificationText: text
        )
    }

    private func commit() {
        let revision = editor.snapshot.revision
        do {
            try store.saveImmediately(editor.snapshot)
        } catch {
            fputs("HarnessDaemon snapshot save failed: \(error)\n", stderr)
        }
        NotificationBus.shared.postSnapshotChanged(revision: revision)
        onSnapshotCommitted?(revision)
    }

    private func createOrEnsureSurface(
        surfaceID: String,
        cwd: String?,
        shell: String?,
        rows: UInt16,
        cols: UInt16,
        scrollbackBytes: Int?
    ) -> String? {
        if sessions[surfaceID] != nil {
            // Existing surface: do NOT resize here. A surface's geometry is owned by the
            // per-client resize votes (`resizeSurface`), which every client sends once its
            // view (GUI) or TTY (CLI attach) lays out. `ensureSurface` carries only a
            // placeholder 24×80 — resizing a live PTY to that on every reattach (e.g. an app
            // relaunch that re-grabs daemon-kept surfaces) storms SIGWINCH: the shell redraws
            // its prompt at 80 cols, that redraw overlaps the replayed scrollback (captured at
            // the real width) and the real resize that immediately follows, leaving the garbled
            // overlapping prompt seen on terminal restart. Returning early keeps the surface at
            // its real size until the client's own resize vote arrives.
            return surfaceID
        }
        do {
            let shellPath = Self.resolveShell(shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            let workDir = existingWorkingDirectory(cwd)
            let session = try RealPty(
                id: surfaceID,
                cwd: workDir,
                shell: shellPath,
                rows: rows,
                cols: cols,
                scrollbackBytes: scrollbackBytes ?? 1024 * 1024,
                extraEnvironment: extraEnvironment(forSurfaceKey: surfaceID)
            )
            session.onExit = { [weak self, weak session] in
                self?.removeSurfaceIfCurrent(surfaceID: surfaceID, session: session)
            }
            // Internal monitor subscription (Phase 5): cheap output/bell/idle tracking, drained
            // by `processMonitors`. Lives for the surface's lifetime (cleared on teardown).
            _ = session.subscribe { [weak self] data, _ in self?.noteSurfaceOutput(surfaceKey: surfaceID, data: data) }
            sessions[surfaceID] = session
            return surfaceID
        } catch {
            fputs("HarnessDaemon surface launch failed for \(surfaceID): \(error)\n", stderr)
            return nil
        }
    }

    /// Validate the requested shell is executable, falling back (with a log) so a bad
    /// `defaultShell` doesn't produce a silently dead pane (`forkpty` child _exit(127)).
    private static func resolveShell(_ candidate: String) -> String {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: candidate) { return candidate }
        let fallbacks = [ProcessInfo.processInfo.environment["SHELL"], "/bin/zsh", "/bin/bash", "/bin/sh"]
            .compactMap { $0 }
        for fallback in fallbacks where fm.isExecutableFile(atPath: fallback) {
            fputs("HarnessDaemon: shell '\(candidate)' is not executable; falling back to '\(fallback)'\n", stderr)
            return fallback
        }
        return candidate
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

    private func ensureTabSurfaces(tabID: TabID) {
        let tabs = editor.snapshot.workspaces.flatMap { workspace in workspace.sessions.flatMap { $0.tabs } }
        guard let tab = tabs.first(where: { $0.id == tabID })
        else { return }
        for surfaceID in tab.rootPane.allSurfaceIDs() {
            _ = createOrEnsureSurface(
                surfaceID: surfaceID.uuidString,
                cwd: tab.cwd,
                shell: nil,
                rows: 24,
                cols: 80,
                scrollbackBytes: nil
            )
        }
    }

    private func ensureSessionSurfaces(sessionID: SessionID) {
        let allSessions = editor.snapshot.workspaces.flatMap { $0.sessions }
        guard let session = allSessions.first(where: { $0.id == sessionID })
        else { return }
        for tab in session.tabs {
            for surfaceID in tab.rootPane.allSurfaceIDs() {
                _ = createOrEnsureSurface(
                    surfaceID: surfaceID.uuidString,
                    cwd: tab.cwd,
                    shell: nil,
                    rows: 24,
                    cols: 80,
                    scrollbackBytes: nil
                )
            }
        }
    }

    private func ensureAllSnapshotSurfaces() {
        for tab in editor.snapshot.workspaces.flatMap({ workspace in workspace.sessions.flatMap { $0.tabs } }) {
            for surfaceID in tab.rootPane.allSurfaceIDs() {
                _ = createOrEnsureSurface(
                    surfaceID: surfaceID.uuidString,
                    cwd: tab.cwd,
                    shell: nil,
                    rows: 24,
                    cols: 80,
                    scrollbackBytes: nil
                )
            }
        }
    }

    /// Close PTYs for the given surfaces — but only those no longer referenced by
    /// any surviving tab. Linked windows (`link-window`) share surfaces across
    /// tabs/sessions, so a surface lives until its last referencing tab is gone.
    /// Called after the editor mutation, so `editor.snapshot` reflects survivors.
    private func closeSurfaces(_ surfaceIDs: [String]) {
        let stillReferenced = Set(
            editor.snapshot.workspaces
                .flatMap { $0.sessions }
                .flatMap { $0.tabs }
                .flatMap { $0.rootPane.allSurfaceIDs().map(\.uuidString) }
        )
        for surfaceID in surfaceIDs where !stillReferenced.contains(surfaceID) {
            sessions.removeValue(forKey: surfaceID)?.close()
            stopPipe(surfaceID: surfaceID)
            // Drop the output monitor too, else it leaks across tab/session/pane churn.
            monitorLock.lock(); monitors.removeValue(forKey: surfaceID); monitorLock.unlock()
        }
    }

    // MARK: pipe-pane

    /// Active `pipe-pane` taps: a surface's live output is tee'd to a spawned
    /// shell command's stdin until toggled off (or the surface closes).
    private struct PanePipe {
        let process: Process
        let stdin: FileHandle
        let token: UUID
    }
    private var pipes: [String: PanePipe] = [:]

    /// Caller holds `lock` (invoked from `handle`/`closeSurfaces`), so this talks to
    /// the `RealPty` directly rather than the locking `subscribe` wrappers.
    private func startPipe(surfaceID: String, shellCommand: String) {
        stopPipe(surfaceID: surfaceID)   // one pipe per surface
        guard let session = sessions[surfaceID] else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", shellCommand]
        let stdin = Pipe()
        process.standardInput = stdin
        process.environment = ProcessInfo.processInfo.environment
        guard (try? process.run()) != nil else {
            // Never log the command itself — a pipe target can carry tokens/paths the user
            // would not want in daemon stderr. The surface id is enough to diagnose.
            fputs("HarnessDaemon: pipe-pane failed to launch for surface \(surfaceID)\n", stderr)
            return
        }
        let writer = stdin.fileHandleForWriting
        let token = session.subscribe { data, _ in
            // Best-effort: a broken pipe (consumer exited) just drops bytes.
            _ = try? writer.write(contentsOf: data)
        }
        pipes[surfaceID] = PanePipe(process: process, stdin: writer, token: token)
    }

    private func stopPipe(surfaceID: String) {
        guard let pipe = pipes.removeValue(forKey: surfaceID) else { return }
        sessions[surfaceID]?.cancelSubscription(token: pipe.token)
        try? pipe.stdin.close()
        if pipe.process.isRunning { pipe.process.terminate() }
    }

    /// Whether OSC/program title auto-rename is enabled for the tab owning
    /// `surfaceKey` (per-tab `automatic-rename`, defaulting on).
    private func automaticRenameEnabled(forSurfaceKey surfaceKey: String) -> Bool {
        guard let match = editor.tab(forSurfaceKey: surfaceKey) else { return true }
        return optionStore.get("automatic-rename", scope: .tab, target: match.tabID.uuidString)?.boolValue ?? true
    }

    /// The extra environment a pane's shell receives: Harness-owned vars (so
    /// nested tools detect Harness, the `$TMUX` analog) plus the resolved
    /// `set-environment` map for the surface's owning session.
    private func extraEnvironment(forSurfaceKey surfaceKey: String) -> [String: String] {
        var env: [String: String] = [
            "HARNESS": HarnessPaths.socketURL.path,
            "HARNESS_SOCK": HarnessPaths.socketURL.path,
        ]
        let session = sessionID(forSurfaceKey: surfaceKey)
        for (key, value) in environmentStore.resolved(sessionID: session) { env[key] = value }
        return env
    }

    private func sessionID(forSurfaceKey surfaceKey: String) -> String? {
        guard let uuid = UUID(uuidString: surfaceKey) else { return nil }
        for ws in editor.snapshot.workspaces {
            for session in ws.sessions {
                for tab in session.tabs where tab.rootPane.allSurfaceIDs().contains(uuid) {
                    return session.id.uuidString
                }
            }
        }
        return nil
    }

    private func removeSurfaceIfCurrent(surfaceID: String, session: RealPty?) {
        lock.lock()
        guard let session, sessions[surfaceID] === session else { lock.unlock(); return }
        sessions.removeValue(forKey: surfaceID)
        monitorLock.lock(); monitors.removeValue(forKey: surfaceID); monitorLock.unlock()
        // Natural shell exit must also tear down an active pipe-pane tap, else its `/bin/sh`
        // consumer + write-FD leak (every other close path already calls stopPipe).
        stopPipe(surfaceID: surfaceID)
        AgentDetector.unregisterRootPID(forSurfaceKey: surfaceID)
        // `remain-on-exit` (default on, Harness's safe default): keep the dead leaf so the
        // surface key still resolves and `respawn-pane` can revive it. Off → close the pane
        // (or the whole tab when it was the pane's last). The close reuses the normal IPC
        // handlers, so it must run off the registry lock — resolve the target here, dispatch
        // there.
        let keep = optionStore.get("remain-on-exit")?.boolValue ?? true
        let toClose = keep ? nil : editor.paneLocation(forSurfaceKey: surfaceID)
        fireHookLocked(.paneExited, surfaceKey: surfaceID)
        lock.unlock()

        if let toClose {
            hookQueue.async { [weak self] in
                guard let self else { return }
                if toClose.paneCount > 1 {
                    _ = self.handle(.killPane(paneID: toClose.paneID))
                } else {
                    _ = self.handle(.closeTab(tabID: toClose.tabID))
                }
            }
        }
    }
}
