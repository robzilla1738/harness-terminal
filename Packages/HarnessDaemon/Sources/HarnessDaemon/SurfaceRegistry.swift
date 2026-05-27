import Foundation
import HarnessCore

/// Single source of truth for Harness session layout and notifications.
public final class SurfaceRegistry: @unchecked Sendable {
    private var sessions: [DaemonSurfaceID: RealPty] = [:]
    private var editor = SessionEditor()
    private let store = SessionStore()
    private let lock = NSLock()

    public init() {
        editor.snapshot = store.load()
        if editor.snapshot.workspaces.isEmpty {
            editor.snapshot = SessionSnapshot()
            store.save(editor.snapshot)
        }
        ensureAllSnapshotSurfaces()
    }

    public var snapshot: SessionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return editor.snapshot
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
            return .sessionID(sessionID)
        case let .newTab(workspaceID, cwd):
            guard let tabID = editor.addTab(to: workspaceID, cwd: cwd) else {
                return .error("Workspace not found")
            }
            ensureTabSurfaces(tabID: tabID)
            commit()
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
            return .tabID(tabID)
        case let .newSplit(tabID, paneID, direction):
            guard let workspace = editor.snapshot.workspaces.first(where: { ws in
                ws.sessions.contains { session in session.tabs.contains { $0.id == tabID } }
            }) else { return .error("Tab not found") }
            let tab = workspace.sessions.flatMap { $0.tabs }.first { $0.id == tabID }
            let targetPane = paneID ?? tab?.rootPane.allPaneIDs().first
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
            return .paneID(newPaneID)
        case let .selectWorkspace(id):
            editor.selectWorkspace(id)
            commit()
            return .ok
        case let .selectWorkspaceByName(name):
            guard let id = editor.resolveWorkspaceID(nameOrID: name) else {
                return .error("Workspace not found: \(name)")
            }
            editor.selectWorkspace(id)
            commit()
            return .workspaceID(id)
        case let .selectSession(workspaceID, sessionID):
            editor.selectSession(workspaceID: workspaceID, sessionID: sessionID)
            commit()
            return .ok
        case let .selectTab(workspaceID, tabID):
            editor.selectTab(workspaceID: workspaceID, tabID: tabID)
            commit()
            return .ok
        case let .closeTab(tabID):
            let closedSurfaces = editor.snapshot.workspaces
                .flatMap { workspace in workspace.sessions.flatMap { $0.tabs } }
                .first(where: { $0.id == tabID })?
                .rootPane
                .allSurfaceIDs()
                .map(\.uuidString) ?? []
            guard editor.closeTab(tabID) else { return .error("Tab not found") }
            closeSurfaces(closedSurfaces)
            ensureAllSnapshotSurfaces()
            commit()
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
            editor.snapshot.themeName = name
            commit()
            return .ok
        case let .setKeepSessionsOnQuit(value):
            editor.snapshot.keepSessionsOnQuit = value
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
            return .ok
        case let .clearNotification(surfaceID):
            if let uuid = UUID(uuidString: surfaceID) {
                editor.clearTabNotification(surfaceID: uuid)
            }
            commit()
            return .ok
        case let .updateTabTitle(surfaceID, title):
            if let uuid = UUID(uuidString: surfaceID) {
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
            let bytes = TmuxKeyParser.encode(keys: keys)
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
        case let .killPane(paneID):
            let killedSurfaceID = editor.surfaceID(forPaneID: paneID)?.uuidString
            guard editor.killPane(paneID) else { return .error("Pane not found") }
            if let killedSurfaceID { closeSurfaces([killedSurfaceID]) }
            commit()
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
        case let .subscribeSurfaceOutput(surfaceID):
            return subscribe(surfaceID: surfaceID)
        case let .cancelSubscription(surfaceID):
            sessions[surfaceID]?.cancelSubscription()
            return .ok
        case let .replayScrollback(surfaceID, fromSequence):
            guard let session = sessions[surfaceID] else { return .text("") }
            return .text(session.replay(fromSequence: fromSequence))
        case let .resizeSurface(surfaceID, rows, cols):
            sessions[surfaceID]?.resize(rows: rows, cols: cols)
            return .ok
        case let .detachSurface(surfaceID):
            sessions[surfaceID]?.detachSubscriber()
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
        for (surfaceKey, snapshot) in changes {
            editor.setAgent(snapshot, forSurfaceKey: surfaceKey)
        }
        commit()
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
        store.save(editor.snapshot)
        NotificationBus.shared.postSnapshotChanged(revision: revision)
    }

    private func createOrEnsureSurface(
        surfaceID: String,
        cwd: String?,
        shell: String?,
        rows: UInt16,
        cols: UInt16,
        scrollbackBytes: Int?
    ) -> String? {
        if let existing = sessions[surfaceID] {
            existing.resize(rows: rows, cols: cols)
            return surfaceID
        }
        do {
            let shellPath = shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let workDir = existingWorkingDirectory(cwd)
            let session = try RealPty(
                id: surfaceID,
                cwd: workDir,
                shell: shellPath,
                rows: rows,
                cols: cols,
                scrollbackBytes: scrollbackBytes ?? 1024 * 1024
            )
            sessions[surfaceID] = session
            return surfaceID
        } catch {
            fputs("HarnessDaemon surface launch failed for \(surfaceID): \(error)\n", stderr)
            return nil
        }
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

    private func closeSurfaces(_ surfaceIDs: [String]) {
        for surfaceID in surfaceIDs {
            sessions.removeValue(forKey: surfaceID)?.close()
        }
    }
}
