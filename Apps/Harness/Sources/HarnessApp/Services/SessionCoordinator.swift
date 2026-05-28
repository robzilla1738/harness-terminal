import AppKit
import Foundation
import HarnessCore
import HarnessTerminalKit
import UserNotifications

@MainActor
final class SessionCoordinator: NSObject {
    static let shared = SessionCoordinator()

    private let daemon = DaemonSessionService()
    private(set) var snapshot = SessionSnapshot()
    private var lastRevision = -1
    private let terminalHosts = TerminalPaneRegistry()
    private var metadataTask: Task<Void, Never>?
    private var pushedNotificationKeys: Set<String> = []
    var settings = HarnessSettings.load()
    var activeSurfaceID: SurfaceID?
    var structureRevision = 0

    private enum ActiveTabCloseDisposition {
        case tab
        case session
        case workspace
        case window
    }

    private struct CloseConfirmationCopy {
        var message: String
        var informative: String
        var button: String
    }

    private override init() {
        super.init()
        syncFromDaemon()
        observeNotifications()
        startMetadataRefresh()
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(snapshotChangedNotification(_:)),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(notificationPosted(_:)),
            name: NotificationBus.shared.notificationPosted,
            object: nil
        )
    }

    @objc private func snapshotChangedNotification(_ note: Notification) {
        let revision = note.userInfo?["revision"] as? Int ?? -1
        guard revision != lastRevision else { return }
        syncFromDaemon()
    }

    @objc private func notificationPosted(_ note: Notification) {
        guard let notification = note.userInfo?["notification"] as? AgentNotification else { return }
        if let surfaceID = notification.surfaceID {
            terminalHosts.host(for: surfaceID)?.showsWaitingRing = true
        }
        NotificationCenter.default.post(name: NotificationBus.shared.tabStatusChanged, object: nil)
    }

    func syncFromDaemon(metadataOnly: Bool = false) {
        guard let remote = try? daemon.fetchSnapshot() else { return }
        let structureChanged = structureFingerprint(remote) != structureFingerprint(snapshot)
        snapshot = remote
        lastRevision = remote.revision
        if structureChanged {
            structureRevision += 1
        }
        pushNewRemoteNotifications(from: remote)
        if !metadataOnly {
            applyThemeToAllHosts()
        }
        syncWaitingRings()
        updateDockBadge(from: remote)
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: [
                "revision": remote.revision,
                "structureChanged": structureChanged,
                "chromeChanged": !metadataOnly,
                "metadataOnly": metadataOnly,
            ]
        )
    }

    private func structureFingerprint(_ snap: SessionSnapshot) -> String {
        guard let ws = snap.activeWorkspace, let session = ws.activeSession, let tab = session.activeTab else { return "" }
        let surfaces = tab.rootPane.allSurfaceIDs().map(\.uuidString).sorted().joined(separator: ",")
        return "\(ws.id)|\(session.id)|\(tab.id)|\(surfaces)"
    }

    private func applyThemeToAllHosts() {
        HarnessChrome.update(
            themeName: snapshot.themeName,
            opacity: CGFloat(settings.backgroundOpacity),
            blur: settings.backgroundBlur,
            backgroundHex: settings.useCustomColors ? settings.customBackgroundHex : nil,
            foregroundHex: settings.useCustomColors ? settings.customForegroundHex : nil,
            cursorHex: settings.useCustomColors ? settings.customCursorHex : nil
        )
        for host in terminalHosts.allHosts() {
            if shouldApplyNamedTerminalTheme {
                host.applyTheme(named: snapshot.themeName)
            }
            host.applySettings(settings)
            pushBorderColors(to: host)
        }
    }

    /// Always apply the selected theme to terminals as the base palette; custom colors
    /// are layered on top afterward in `applySettings`. Previously this was skipped when
    /// a custom background/foreground was set, which also dropped the theme's ANSI
    /// palette — so e.g. a custom black background silently lost the theme's syntax
    /// colors. Layering (theme first, overrides second) keeps both.
    private var shouldApplyNamedTerminalTheme: Bool { true }

    /// Push the theme's focus-ring / waiting colors into a host (the terminal package
    /// can't reach the app palette, so the app owns these indicator colors).
    private func pushBorderColors(to host: TerminalHostView) {
        host.applyBorderColors(active: HarnessChrome.current.focusRing, waiting: HarnessChrome.current.waiting)
    }

    private func syncWaitingRings() {
        for host in terminalHosts.allHosts() {
            if let match = snapshot.workspaces.flatMap({ workspace in workspace.sessions.flatMap { $0.tabs } }).first(where: { tab in
                tab.rootPane.allSurfaceIDs().contains(host.surfaceID)
            }) {
                host.showsWaitingRing = match.status == .waiting
            }
        }
    }

    private func pushNewRemoteNotifications(from snapshot: SessionSnapshot) {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.status == .waiting {
                    guard let text = tab.notificationText, !text.isEmpty,
                          let surfaceID = tab.rootPane.allSurfaceIDs().first
                    else { continue }
                    let key = "\(surfaceID.uuidString)|\(text)"
                    guard !pushedNotificationKeys.contains(key) else { continue }
                    pushedNotificationKeys.insert(key)
                    terminalHosts.host(for: surfaceID)?.showsWaitingRing = true
                    if settings.systemNotificationsEnabled {
                        let agentLabel = tab.agent?.kind.displayName ?? "Harness"
                        let title = "\(agentLabel) · \(tab.title.isEmpty ? "Terminal" : tab.title)"
                        DesktopNotifier.show(title: title, body: text)
                    }
                }
            }
        }
        // Snapshot also clears keys whose notification has been dismissed remotely
        // so a re-arming of the same tab+text can fire a new notification later.
        let live = Set(snapshot.workspaces.flatMap { ws in
            ws.sessions.flatMap { ses in
                ses.tabs.compactMap { tab -> String? in
                    guard tab.status == .waiting, let text = tab.notificationText, !text.isEmpty,
                          let surfaceID = tab.rootPane.allSurfaceIDs().first
                    else { return nil }
                    return "\(surfaceID.uuidString)|\(text)"
                }
            }
        })
        pushedNotificationKeys = pushedNotificationKeys.intersection(live)
    }

    private func updateDockBadge(from snapshot: SessionSnapshot) {
        let waiting = snapshot.workspaces.reduce(into: 0) { count, workspace in
            count += workspace.sessions
                .flatMap(\.tabs)
                .filter { $0.status == .waiting }
                .count
        }
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    func saveImmediately() {
        syncFromDaemon()
    }

    /// Push the current `settings` to every live terminal host and refresh chrome.
    func applySettingsToHosts() {
        HarnessChrome.update(
            themeName: snapshot.themeName,
            opacity: CGFloat(settings.backgroundOpacity),
            blur: settings.backgroundBlur,
            backgroundHex: settings.useCustomColors ? settings.customBackgroundHex : nil,
            foregroundHex: settings.useCustomColors ? settings.customForegroundHex : nil,
            cursorHex: settings.useCustomColors ? settings.customCursorHex : nil
        )
        for host in terminalHosts.allHosts() {
            if shouldApplyNamedTerminalTheme {
                host.applyTheme(named: snapshot.themeName)
            }
            host.applySettings(settings)
            pushBorderColors(to: host)
        }
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: [
                "revision": snapshot.revision,
                "structureChanged": false,
                "chromeChanged": true,
            ]
        )
    }

    func setTheme(_ name: String, clearColorOverrides: Bool = false) {
        if clearColorOverrides {
            settings.customBackgroundHex = nil
            settings.customForegroundHex = nil
            settings.customCursorHex = nil
            settings.useCustomColors = false
            try? settings.save()
        }
        requestDaemon(.setTheme(name: name))
        syncFromDaemon()
    }

    func addWorkspace(name: String) {
        requestDaemon(.newWorkspace(name: name))
        syncFromDaemon()
    }

    func addSession(to workspaceID: WorkspaceID, cwd: String? = nil, name: String? = nil) {
        requestDaemon(.newSession(workspaceID: workspaceID, cwd: cwd ?? settings.defaultCWD, name: name))
        syncFromDaemon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SurfaceShellTracker.shared.bumpScan()
        }
    }

    func addTab(to workspaceID: WorkspaceID, cwd: String? = nil) {
        requestDaemon(.newTab(workspaceID: workspaceID, cwd: cwd ?? settings.defaultCWD))
        syncFromDaemon()
        // The shell will spawn imminently — kick the cwd tracker so the new
        // tab's path lights up without waiting for the next 500ms tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            SurfaceShellTracker.shared.bumpScan()
        }
    }

    func splitActivePane(direction: SplitDirection) {
        guard let workspace = snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let paneID = activeSurfaceID.flatMap({ paneID(for: $0, in: tab.rootPane) })
                ?? tab.rootPane.allPaneIDs().last
        else { return }
        requestDaemon(.newSplit(tabID: tab.id, paneID: paneID, direction: direction))
        syncFromDaemon()
    }

    private func paneID(for surfaceID: SurfaceID, in node: PaneNode) -> PaneID? {
        switch node {
        case let .leaf(leaf) where leaf.surfaceID == surfaceID:
            return leaf.id
        case let .branch(_, _, first, second):
            return paneID(for: surfaceID, in: first) ?? paneID(for: surfaceID, in: second)
        default:
            return nil
        }
    }

    func selectWorkspace(_ id: WorkspaceID) {
        requestDaemon(.selectWorkspace(id: id))
        syncFromDaemon()
    }

    func selectSession(workspaceID: WorkspaceID, sessionID: SessionID) {
        if snapshot.activeWorkspaceID == workspaceID,
           snapshot.activeWorkspace?.activeSessionID == sessionID
        {
            return
        }
        requestDaemon(.selectSession(workspaceID: workspaceID, sessionID: sessionID))
        syncFromDaemon()
    }

    func selectTab(workspaceID: WorkspaceID, tabID: TabID) {
        if snapshot.activeWorkspaceID == workspaceID,
           snapshot.activeWorkspace?.activeTabID == tabID
        {
            return
        }
        requestDaemon(.selectTab(workspaceID: workspaceID, tabID: tabID))
        syncFromDaemon()
    }

    func selectAdjacentTab(offset: Int) {
        guard let workspace = snapshot.activeWorkspace,
              let activeTabID = workspace.activeTabID,
              let index = workspace.tabs.firstIndex(where: { $0.id == activeTabID }),
              !workspace.tabs.isEmpty
        else { return }
        let count = workspace.tabs.count
        let nextIndex = (index + offset % count + count) % count
        selectTab(workspaceID: workspace.id, tabID: workspace.tabs[nextIndex].id)
    }

    func closeActiveTab() {
        guard let disposition = activeTabCloseDisposition() else { return }
        performClose(disposition)
    }

    private func closeActiveTabOnly() {
        guard let tabID = snapshot.activeWorkspace?.activeTab?.id else { return }
        let surfaces = snapshot.activeWorkspace?.activeTab?.rootPane.allSurfaceIDs() ?? []
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemon(.closeTab(tabID: tabID))
        syncFromDaemon()
    }

    func closeActiveTabWithConfirmation() {
        guard let disposition = activeTabCloseDisposition(),
              let copy = closeConfirmationCopy(for: disposition)
        else { return }
        let alert = NSAlert()
        alert.messageText = copy.message
        alert.informativeText = copy.informative
        alert.alertStyle = .warning
        alert.addButton(withTitle: copy.button)
        alert.addButton(withTitle: "Cancel")

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { [weak self, weak window] response in
                guard response == .alertFirstButtonReturn else { return }
                Task { @MainActor in
                    self?.performClose(disposition, closingWindow: window)
                }
            }
        } else {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            performClose(disposition)
        }
    }

    private func activeTabCloseDisposition() -> ActiveTabCloseDisposition? {
        guard let workspace = snapshot.activeWorkspace,
              let session = workspace.activeSession,
              session.activeTab != nil
        else { return nil }
        if session.tabs.count > 1 { return .tab }
        if workspace.sessions.count > 1 { return .session }
        if snapshot.workspaces.count > 1 { return .workspace }
        return .window
    }

    private func closeConfirmationCopy(for disposition: ActiveTabCloseDisposition) -> CloseConfirmationCopy? {
        guard let workspace = snapshot.activeWorkspace,
              let session = workspace.activeSession,
              let tab = session.activeTab
        else { return nil }
        let tabTitle = HarnessPathDisplay.title(for: tab.cwd, fallback: tab.title)
        switch disposition {
        case .tab:
            return CloseConfirmationCopy(
                message: "Close tab \"\(tabTitle)\"?",
                informative: "This will close the tab and its running shell.",
                button: "Close Tab"
            )
        case .session:
            let sessionTitle = session.name.isEmpty ? tabTitle : session.name
            return CloseConfirmationCopy(
                message: "Close session \"\(sessionTitle)\"?",
                informative: "This is the last tab in the session. The session and its running shell will close.",
                button: "Close Session"
            )
        case .workspace:
            return CloseConfirmationCopy(
                message: "Close workspace \"\(workspace.name)\"?",
                informative: "This is the last tab in the workspace. The workspace and its running shell will close.",
                button: "Close Workspace"
            )
        case .window:
            return CloseConfirmationCopy(
                message: "Close Harness window?",
                informative: "This is the last tab in the window. The running shell will close and the window will close.",
                button: "Close Window"
            )
        }
    }

    private func performClose(_ disposition: ActiveTabCloseDisposition, closingWindow: NSWindow? = nil) {
        switch disposition {
        case .tab:
            closeActiveTabOnly()
        case .session:
            closeActiveSession()
        case .workspace:
            closeActiveWorkspace()
        case .window:
            closeActiveTabOnly()
            (closingWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)?.close()
        }
    }

    func closeActiveSession() {
        guard let sessionID = snapshot.activeWorkspace?.activeSession?.id else { return }
        let surfaces = snapshot.activeWorkspace?.activeSession?.tabs.flatMap { $0.rootPane.allSurfaceIDs() } ?? []
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemon(.closeSession(sessionID: sessionID))
        syncFromDaemon()
    }

    func openTabInActiveWorkspace() {
        guard let workspace = snapshot.activeWorkspace else { return }
        addTab(to: workspace.id)
    }

    /// Close every tab in the active session except `keepID` (the "Close Others"
    /// context action). Frees each closed tab's terminal hosts.
    func closeOtherTabs(keeping keepID: TabID) {
        guard let workspace = snapshot.activeWorkspace, let session = workspace.activeSession else { return }
        let others = session.tabs.filter { $0.id != keepID }
        guard !others.isEmpty else { return }
        for tab in others {
            for surfaceID in tab.rootPane.allSurfaceIDs() {
                terminalHosts.removeHost(for: surfaceID)
            }
            requestDaemon(.closeTab(tabID: tab.id))
        }
        selectTab(workspaceID: workspace.id, tabID: keepID)
        syncFromDaemon()
    }

    /// Select a tab, then split its active pane — used by the tab context menu so the
    /// split lands in the right tab regardless of which tab was previously active.
    func splitTab(workspaceID: WorkspaceID, tabID: TabID, direction: SplitDirection) {
        selectTab(workspaceID: workspaceID, tabID: tabID)
        splitActivePane(direction: direction)
    }

    func killActivePane() {
        guard let workspace = snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let paneID = activeSurfaceID.flatMap({ paneID(for: $0, in: tab.rootPane) })
                ?? tab.rootPane.allPaneIDs().last
        else { return }
        requestDaemon(.killPane(paneID: paneID))
        syncFromDaemon()
    }

    func zoomActivePane() {
        guard let workspace = snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let paneID = activeSurfaceID.flatMap({ paneID(for: $0, in: tab.rootPane) })
                ?? tab.rootPane.allPaneIDs().last
        else { return }
        requestDaemon(.zoomPane(paneID: paneID))
        syncFromDaemon()
    }

    func cycleActivePane(forward: Bool) {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        let panes = tab.rootPane.allPaneIDs()
        guard !panes.isEmpty else { return }
        let currentIndex: Int
        if let surfaceID = activeSurfaceID,
           let pane = paneID(for: surfaceID, in: tab.rootPane),
           let idx = panes.firstIndex(of: pane)
        {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        let nextIndex = (currentIndex + (forward ? 1 : -1) + panes.count) % panes.count
        let targetPane = panes[nextIndex]
        if let surfaceID = surfaceID(forPane: targetPane, in: tab.rootPane) {
            setActiveSurface(surfaceID)
            terminalHosts.host(for: surfaceID)?.focusTerminal()
        }
    }

    /// Single source of truth for which pane shows the active-pane border. Setting it
    /// updates `activeSurfaceID` and toggles the border on every live host so exactly
    /// one pane (app-wide) is highlighted — but only when its tab is actually split.
    /// A lone terminal needs no "which pane is focused" hint, so it stays borderless.
    func setActiveSurface(_ surfaceID: SurfaceID?) {
        activeSurfaceID = surfaceID
        let showBorder = surfaceID.map { paneCount(forSurface: $0) > 1 } ?? false
        for host in terminalHosts.allHosts() {
            host.showsActiveBorder = showBorder && host.surfaceID == surfaceID
        }
    }

    /// Number of panes in the tab that owns `surfaceID` (1 when unsplit).
    private func paneCount(forSurface surfaceID: SurfaceID) -> Int {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    let ids = tab.rootPane.allSurfaceIDs()
                    if ids.contains(surfaceID) { return ids.count }
                }
            }
        }
        return 0
    }

    /// Re-assert the active-pane border after a (re)mount of `tab`'s panes. If the
    /// tracked active surface isn't part of this tab, fall back to its first pane so
    /// a freshly shown tab always has a clearly focused pane.
    func ensureActivePane(for tab: Tab) {
        let surfaces = tab.rootPane.allSurfaceIDs()
        guard !surfaces.isEmpty else { return }
        let target = activeSurfaceID.flatMap { surfaces.contains($0) ? $0 : nil } ?? surfaces.first
        setActiveSurface(target)
    }

    /// Persist a divider drag. Metadata-only sync: ratio isn't part of the structure
    /// fingerprint, so this never remounts panes or re-fades the chrome.
    func setSplitRatio(tabID: TabID, firstPaneID: PaneID, secondPaneID: PaneID, ratio: Double) {
        requestDaemon(.resizePaneRatio(tabID: tabID, firstPaneID: firstPaneID, secondPaneID: secondPaneID, ratio: ratio))
        syncFromDaemon(metadataOnly: true)
    }

    /// Commit a tab drag-reorder. Full sync so the tab bar rebuilds in the new order
    /// (the metadata path updates pills in place by ID and wouldn't reflect a reorder).
    func reorderSession(workspaceID: WorkspaceID, sessionID: SessionID, toIndex: Int) {
        requestDaemon(.reorderSession(workspaceID: workspaceID, sessionID: sessionID, toIndex: toIndex))
        syncFromDaemon()
    }

    func renameWorkspace(id: WorkspaceID, name: String) {
        requestDaemon(.renameWorkspace(workspaceID: id, name: name))
        syncFromDaemon()
    }

    func reorderTab(workspaceID: WorkspaceID, tabID: TabID, toIndex: Int) {
        requestDaemon(.reorderTab(workspaceID: workspaceID, tabID: tabID, toIndex: toIndex))
        syncFromDaemon()
    }

    private func surfaceID(forPane paneID: PaneID, in node: PaneNode) -> SurfaceID? {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID:
            return leaf.surfaceID
        case let .branch(_, _, first, second):
            return surfaceID(forPane: paneID, in: first) ?? surfaceID(forPane: paneID, in: second)
        default:
            return nil
        }
    }

    func toggleCopyMode() {
        guard let surfaceID = activeSurfaceID else { return }
        let response = requestDaemon(.capturePane(surfaceID: surfaceID.uuidString, includeScrollback: true))
        if case let .text(text) = response {
            CopyModeViewController.shared.present(surfaceID: surfaceID, text: text)
        }
    }

    func detachActiveSurface() {
        guard let surfaceID = activeSurfaceID else { return }
        requestDaemon(.detachSurface(surfaceID: surfaceID.uuidString))
    }

    func selectWorkspace(byIndex index: Int) {
        guard index >= 0, index < snapshot.workspaces.count else { return }
        selectWorkspace(snapshot.workspaces[index].id)
    }

    func beginRenameActiveTab() {
        NotificationCenter.default.post(name: NotificationBus.shared.snapshotChanged, object: nil, userInfo: ["beginRenameActiveTab": true])
    }

    func reimportFromGhostty() {
        if let imported = GhosttyConfigImporter.load() {
            settings = HarnessSettings.makeDefaults(imported: imported)
            try? settings.save()
            if let theme = imported.themeName {
                setTheme(theme)
            } else {
                setTheme(ThemeManager.defaultDisplayName)
            }
            applySettingsToHosts()
        }
    }

    func closeActiveWorkspace() {
        guard let id = snapshot.activeWorkspaceID, snapshot.workspaces.count > 1 else { return }
        closeWorkspace(id: id)
    }

    func closeWorkspace(id: WorkspaceID) {
        guard snapshot.workspaces.count > 1 else { return }
        let surfaces = snapshot.workspaces.first(where: { $0.id == id })?.sessions.flatMap { session in
            session.tabs.flatMap { $0.rootPane.allSurfaceIDs() }
        } ?? []
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemon(.closeWorkspace(id: id))
        syncFromDaemon()
    }

    func terminalHostIfExists(for surfaceID: SurfaceID) -> TerminalHostView? {
        terminalHosts.host(for: surfaceID)
    }

    func terminalHost(for surfaceID: SurfaceID, cwd: String) -> TerminalHostView {
        if let existing = terminalHosts.host(for: surfaceID) {
            return existing
        }
        let host = TerminalHostView(
            surfaceID: surfaceID,
            workingDirectory: cwd,
            harnessSurfaceEnv: surfaceID.uuidString,
            settings: settings,
            themeName: snapshot.themeName
        )
        host.hostDelegate = self
        if shouldApplyNamedTerminalTheme {
            host.applyTheme(named: snapshot.themeName)
        }
        host.applySettings(settings)
        pushBorderColors(to: host)
        terminalHosts.register(host)
        return host
    }

    func jumpToLatestNotification() {
        guard let waiting = firstWaitingTab() else { return }
        selectWorkspace(waiting.workspaceID)
        selectTab(workspaceID: waiting.workspaceID, tabID: waiting.tabID)
    }

    /// All tabs currently `.waiting` plus enough context to render a notification
    /// dropdown row (workspace name, tab title, agent kind, notification body).
    func notificationsList() -> [NotificationEntry] {
        var entries: [NotificationEntry] = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.status == .waiting {
                    guard let surfaceID = tab.rootPane.allSurfaceIDs().first else { continue }
                    entries.append(NotificationEntry(
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        sessionID: session.id,
                        tabID: tab.id,
                        tabTitle: tab.title.isEmpty ? (session.name.isEmpty ? "Terminal" : session.name) : tab.title,
                        surfaceID: surfaceID,
                        agentKind: tab.agent?.kind,
                        body: tab.notificationText ?? "Needs attention"
                    ))
                }
            }
        }
        return entries
    }

    func openNotification(_ entry: NotificationEntry) {
        selectWorkspace(entry.workspaceID)
        selectTab(workspaceID: entry.workspaceID, tabID: entry.tabID)
        clearNotification(surfaceID: entry.surfaceID)
    }

    func clearNotification(surfaceID: SurfaceID) {
        requestDaemon(.clearNotification(surfaceID: surfaceID.uuidString))
        syncFromDaemon()
    }

    func clearAllNotifications() {
        for entry in notificationsList() {
            requestDaemon(.clearNotification(surfaceID: entry.surfaceID.uuidString))
        }
        syncFromDaemon()
    }

    private func firstWaitingTab() -> (workspaceID: WorkspaceID, tabID: TabID)? {
        // Prefer panes whose agent is awaiting input (or a tab is .waiting and
        // the agent is NOT actively generating). Skip panes whose agent is
        // still hammering tokens — those aren't blocked yet.
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                let isWaiting = tab.status == .waiting
                let agentBlocked = tab.agent?.activity == .awaiting
                let agentBusy = tab.agent?.activity == .working
                if (isWaiting && !agentBusy) || agentBlocked {
                    return (workspace.id, tab.id)
                }
                }
            }
        }
        // Fallback: any tab that's `.waiting`, even if its agent is still working.
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.status == .waiting {
                    return (workspace.id, tab.id)
                }
            }
        }
        return nil
    }

    func handleNotification(for surfaceID: SurfaceID, title: String, body: String) {
        requestDaemon(.notify(
            surfaceID: surfaceID.uuidString,
            title: title,
            body: body
        ))
        let key = "\(surfaceID.uuidString)|\(body)"
        pushedNotificationKeys.insert(key)
        terminalHosts.host(for: surfaceID)?.showsWaitingRing = true
        if NSApp.isActive == false {
            DesktopNotifier.show(title: title, body: body)
        }
        syncFromDaemon()
    }

    func clearNotification(for surfaceID: SurfaceID) {
        requestDaemon(.clearNotification(surfaceID: surfaceID.uuidString))
        terminalHosts.host(for: surfaceID)?.showsWaitingRing = false
        syncFromDaemon()
    }

    func updateFontSize(delta: Float) {
        settings.fontSize = max(8, min(32, settings.fontSize + delta))
        try? settings.save()
        for host in terminalHosts.allHosts() {
            host.applySettings(settings)
        }
    }

    private func startMetadataRefresh() {
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            let git = GitMetadataProvider()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let work = await MainActor.run { () -> [(WorkspaceID, Tab)] in
                    guard let self, let workspace = self.snapshot.activeWorkspace else { return [] }
                    return workspace.sessions.flatMap { $0.tabs }.map { (workspace.id, $0) }
                }
                let updates = work.compactMap { workspaceID, tab -> (WorkspaceID, TabID, String?)? in
                    let updated = git.refresh(tab: tab)
                    guard updated.gitBranch != tab.gitBranch else { return nil }
                    return (workspaceID, tab.id, updated.gitBranch)
                }
                await MainActor.run {
                    guard let self else { return }
                    for update in updates {
                        self.logIfFailed(.updateTabGitBranch(
                            workspaceID: update.0,
                            tabID: update.1,
                            branch: update.2
                        ))
                    }
                    self.syncFromDaemon(metadataOnly: true)
                }
            }
        }
    }

    @discardableResult
    func requestDaemon(_ request: IPCRequest) -> IPCResponse? {
        do {
            return try daemon.request(request)
        } catch {
            fputs("Harness daemon request failed: \(error)\n", stderr)
            if NSApp.isActive {
                let alert = NSAlert()
                alert.messageText = "HarnessDaemon request failed"
                alert.informativeText = "\(error)"
                alert.alertStyle = .warning
                alert.runModal()
            }
            return nil
        }
    }

    /// Fire-and-forget metadata update that logs on failure instead of silently
    /// swallowing it. No modal — these (title/cwd/branch) are too frequent to alert on,
    /// but a stale label is worth a diagnostic line.
    private func logIfFailed(_ request: IPCRequest) {
        do {
            _ = try daemon.request(request)
        } catch {
            fputs("Harness daemon metadata update failed: \(error)\n", stderr)
        }
    }
}

extension SessionCoordinator: TerminalHostDelegate {
    func terminalHostDidChangeTitle(_ title: String, surfaceID: SurfaceID) {
        logIfFailed(.updateTabTitle(surfaceID: surfaceID.uuidString, title: title))
        syncFromDaemon(metadataOnly: true)
    }

    func terminalHostDidChangeWorkingDirectory(_ path: String, surfaceID: SurfaceID) {
        logIfFailed(.updateTabCwd(surfaceID: surfaceID.uuidString, path: path))
        syncFromDaemon(metadataOnly: true)
    }

    /// Called by `SurfaceShellTracker` when a polled cwd changes (the OSC 7
    /// fallback for shells that don't emit it).
    func surfaceShellTrackerDidUpdateCwd(_ surfaceID: SurfaceID, cwd: String) {
        // Only push if the daemon's stored value is stale — avoids a feedback
        // loop when libghostty already told us about the same path.
        let current = snapshot.workspaces
            .flatMap { workspace in workspace.sessions.flatMap { $0.tabs } }
            .first { $0.rootPane.allSurfaceIDs().contains(surfaceID) }?.cwd
        if current == cwd { return }
        logIfFailed(.updateTabCwd(surfaceID: surfaceID.uuidString, path: cwd))
        syncFromDaemon(metadataOnly: true)
    }

    func terminalHostDidChangeFocus(_ focused: Bool, surfaceID: SurfaceID) {
        if focused {
            setActiveSurface(surfaceID)
            clearNotification(for: surfaceID)
        }
    }

    func terminalHostDidRingBell(surfaceID: SurfaceID) {
        handleNotification(for: surfaceID, title: "Terminal", body: "Bell")
    }

    func terminalHostDidRequestDesktopNotification(title: String, body: String, surfaceID: SurfaceID) {
        handleNotification(for: surfaceID, title: title, body: body)
    }

    func terminalHostDidClose(surfaceID: SurfaceID) {
        terminalHosts.removeHost(for: surfaceID)
    }
}

struct NotificationEntry: Identifiable, Equatable {
    let workspaceID: WorkspaceID
    let workspaceName: String
    let sessionID: SessionID
    let tabID: TabID
    let tabTitle: String
    let surfaceID: SurfaceID
    let agentKind: AgentKind?
    let body: String
    var id: TabID { tabID }
}

enum DesktopNotifier {
    /// Call once at app launch. macOS only shows the system prompt the first
    /// time; subsequent calls are no-ops, so it's safe to call eagerly.
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

private enum HarnessPathDisplay {
    static func title(for path: String, fallback: String) -> String {
        if path == "/" { return "/" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        let shortened = path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        let last = (String(shortened) as NSString).lastPathComponent
        if !last.isEmpty { return last }
        if !fallback.isEmpty, fallback != "Shell" { return fallback }
        return "Terminal"
    }
}
