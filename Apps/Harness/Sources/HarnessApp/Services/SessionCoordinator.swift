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
    var settings = HarnessSettings.load()
    var activeSurfaceID: SurfaceID?
    var structureRevision = 0

    var keepSessionsOnQuit: Bool { snapshot.keepSessionsOnQuit }

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
        if !metadataOnly {
            applyThemeToAllHosts()
        }
        syncWaitingRings()
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
            backgroundHex: settings.customBackgroundHex,
            foregroundHex: settings.customForegroundHex,
            cursorHex: settings.customCursorHex
        )
        for host in terminalHosts.allHosts() {
            if shouldApplyNamedTerminalTheme {
                host.applyTheme(named: snapshot.themeName)
            }
            host.applySettings(settings)
        }
    }

    private var shouldApplyNamedTerminalTheme: Bool {
        settings.customBackgroundHex == nil && settings.customForegroundHex == nil
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

    func saveImmediately() {
        syncFromDaemon()
    }

    /// Push the current `settings` to every live terminal host and refresh chrome.
    func applySettingsToHosts() {
        HarnessChrome.update(
            themeName: snapshot.themeName,
            opacity: CGFloat(settings.backgroundOpacity),
            backgroundHex: settings.customBackgroundHex,
            foregroundHex: settings.customForegroundHex,
            cursorHex: settings.customCursorHex
        )
        for host in terminalHosts.allHosts() {
            if shouldApplyNamedTerminalTheme {
                host.applyTheme(named: snapshot.themeName)
            }
            host.applySettings(settings)
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
            try? settings.save()
        }
        requestDaemon(.setTheme(name: name))
        syncFromDaemon()
    }

    func setKeepSessionsOnQuit(_ value: Bool) {
        requestDaemon(.setKeepSessionsOnQuit(value))
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
        guard let tabID = snapshot.activeWorkspace?.activeTab?.id else { return }
        let surfaces = snapshot.activeWorkspace?.activeTab?.rootPane.allSurfaceIDs() ?? []
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemon(.closeTab(tabID: tabID))
        syncFromDaemon()
    }

    func closeActiveTabWithConfirmation() {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        let title = HarnessPathDisplay.title(for: tab.cwd, fallback: tab.title)
        let alert = NSAlert()
        alert.messageText = "Close tab \"\(title)\"?"
        alert.informativeText = "This will close the tab and its running shell."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Tab")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        closeActiveTab()
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
            activeSurfaceID = surfaceID
            if let host = terminalHosts.host(for: surfaceID) {
                host.focusTerminal()
            }
        }
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
            CopyModeWindow.show(text: text)
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
            }
            applySettingsToHosts()
        }
    }

    func closeActiveWorkspace() {
        guard let id = snapshot.activeWorkspaceID, snapshot.workspaces.count > 1 else { return }
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
            settings: settings
        )
        host.hostDelegate = self
        if shouldApplyNamedTerminalTheme {
            host.applyTheme(named: snapshot.themeName)
        }
        host.applySettings(settings)
        terminalHosts.register(host)
        return host
    }

    func jumpToLatestNotification() {
        guard let waiting = firstWaitingTab() else { return }
        selectWorkspace(waiting.workspaceID)
        selectTab(workspaceID: waiting.workspaceID, tabID: waiting.tabID)
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
                        _ = try? self.daemon.request(.updateTabGitBranch(
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
    private func requestDaemon(_ request: IPCRequest) -> IPCResponse? {
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
}

extension SessionCoordinator: TerminalHostDelegate {
    func terminalHostDidChangeTitle(_ title: String, surfaceID: SurfaceID) {
        _ = try? daemon.request(.updateTabTitle(surfaceID: surfaceID.uuidString, title: title))
        syncFromDaemon(metadataOnly: true)
    }

    func terminalHostDidChangeWorkingDirectory(_ path: String, surfaceID: SurfaceID) {
        _ = try? daemon.request(.updateTabCwd(surfaceID: surfaceID.uuidString, path: path))
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
        _ = try? daemon.request(.updateTabCwd(surfaceID: surfaceID.uuidString, path: cwd))
        syncFromDaemon(metadataOnly: true)
    }

    func terminalHostDidChangeFocus(_ focused: Bool, surfaceID: SurfaceID) {
        if focused {
            activeSurfaceID = surfaceID
            for host in terminalHosts.allHosts() {
                host.showsActiveBorder = host.surfaceID == surfaceID
            }
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

enum DesktopNotifier {
    static func show(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request)
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

@MainActor
enum CopyModeWindow {
    private static var window: NSWindow?

    static func show(text: String) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: CGFloat(SessionCoordinator.shared.settings.fontSize), weight: .regular)
        textView.string = text
        textView.textColor = HarnessChrome.current.textPrimary
        textView.backgroundColor = HarnessChrome.current.terminalBackground
        scroll.documentView = textView

        let win = window ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Copy Mode"
        win.contentView = scroll
        window = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
