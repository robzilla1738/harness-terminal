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
    /// Last-seen agent activity per surface key, so we can fire a notification the
    /// moment an agent transitions out of `working` (i.e. stopped producing output —
    /// finished its turn or is blocked on you). This is hook-independent, so it works
    /// for any detected agent under any shell.
    private var lastAgentActivity: [String: AgentActivity] = [:]
    /// Cooldown timestamp per surface so a streaming agent that briefly flips
    /// working→idle→working mid-task can't spam "stopped" pings.
    private var lastStopNotifyAt: [String: Date] = [:]
    var settings = HarnessSettings.load()
    var activeSurfaceID: SurfaceID?
    /// Most-recently-active pane within the current tab, for `select-pane -l`
    /// (last-pane). Updated only on genuine intra-tab pane switches.
    private(set) var lastActiveSurfaceID: SurfaceID?
    /// Set while reflecting the daemon's `activePaneID` into local focus, so the
    /// `setActiveSurface` push doesn't echo back to the daemon (feedback loop).
    private var suppressActivePaneSync = false
    /// The marked pane (`select-pane -m`) — implicit source for `join-pane`.
    private(set) var markedSurfaceID: SurfaceID?
    /// Tabs with `synchronize-panes` on — input typed in any pane mirrors to all.
    private var synchronizedTabIDs: Set<TabID> = []
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
        pushAgentActivityNotifications(from: remote)
        if !metadataOnly {
            applyThemeToAllHosts()
        }
        syncWaitingRings()
        updateDockBadge(from: remote)
        reflectRemoteActivePane()
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
            backgroundHex: settings.customBackgroundHex,
            foregroundHex: settings.customForegroundHex,
            cursorHex: settings.customCursorHex
        )
        let allowClipboard = HarnessOptions.shared.get("set-clipboard")?.boolValue ?? true
        for host in terminalHosts.allHosts() {
            host.applyTheme(named: snapshot.themeName)
            host.applySettings(settings)
            host.allowProgramClipboardAccess = allowClipboard
            pushBorderColors(to: host)
        }
        refreshSyncSiblings()
        reassertMarkedPane()
    }

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
                    // Always surface the waiting ring; but don't fire a banner for the pane you're
                    // actively watching — its output + the ring already show it. Defer (don't mark
                    // pushed) so it still fires once you look away, matching the activity path.
                    terminalHosts.host(for: surfaceID)?.showsWaitingRing = true
                    if NSApp.isActive, surfaceID == activeSurfaceID { continue }
                    pushedNotificationKeys.insert(key)
                    let agentLabel = tab.agent?.kind.displayName ?? "Harness"
                    let title = "\(agentLabel) · \(tab.title.isEmpty ? "Terminal" : tab.title)"
                    deliverAgentAlert(title: title, body: text)
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

    /// Hook-independent agent alerts: ping the moment a *detected* agent stops
    /// producing output (transitions out of `working`). The daemon's `AgentDetector`
    /// flips an agent to `idle`/`awaiting` after a few seconds of PTY silence, which is
    /// exactly "the AI stopped or is waiting on you" — so this works for any agent under
    /// any shell, with no hook install required. The explicit `harness-cli notify` path
    /// (richer message) still fires via `pushNewRemoteNotifications`; we skip here when a
    /// tab is already `.waiting` so the two paths never double-ping.
    private func pushAgentActivityNotifications(from snapshot: SessionSnapshot) {
        var live: Set<String> = []
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    guard let agent = tab.agent,
                          let surfaceID = tab.rootPane.allSurfaceIDs().first
                    else { continue }
                    let key = surfaceID.uuidString
                    live.insert(key)
                    let previous = lastAgentActivity[key]
                    lastAgentActivity[key] = agent.activity

                    // Only the working → (idle|awaiting) edge counts as "stopped".
                    let stopped = previous == .working
                        && (agent.activity == .idle || agent.activity == .awaiting)
                    guard stopped else { continue }
                    // The explicit notify path owns `.waiting` tabs (it carries the real
                    // message); don't double-fire.
                    if tab.status == .waiting { continue }
                    // Don't nag for the pane you're already watching.
                    if NSApp.isActive, surfaceID == activeSurfaceID { continue }
                    // Cooldown so a flapping stream can't spam.
                    if let last = lastStopNotifyAt[key], Date().timeIntervalSince(last) < 30 { continue }
                    lastStopNotifyAt[key] = Date()

                    let folder = HarnessDesign.pathDisplayName(tab.cwd)
                    let title = "\(agent.kind.displayName) · \(folder)"
                    deliverAgentAlert(title: title, body: "Finished — waiting for you")
                }
            }
        }
        lastAgentActivity = lastAgentActivity.filter { live.contains($0.key) }
        lastStopNotifyAt = lastStopNotifyAt.filter { live.contains($0.key) }
    }

    /// Single delivery point for agent alerts, honoring the two Settings toggles:
    /// `systemNotificationsEnabled` (push banner) and `notificationSoundEnabled` (chime).
    /// Banner-on carries the sound; banner-off-but-chime-on still plays an in-app chime,
    /// so an agent stopping is audible even when banners are suppressed.
    private func deliverAgentAlert(title: String, body: String) {
        let wantBanner = settings.systemNotificationsEnabled
        let wantChime = settings.notificationSoundEnabled
        guard wantBanner || wantChime else { return }
        if wantBanner {
            DesktopNotifier.show(title: title, body: body, withSound: wantChime)
        } else if wantChime {
            NSSound(named: "Glass")?.play()
        }
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
            backgroundHex: settings.customBackgroundHex,
            foregroundHex: settings.customForegroundHex,
            cursorHex: settings.customCursorHex
        )
        let allowClipboard = HarnessOptions.shared.get("set-clipboard")?.boolValue ?? true
        for host in terminalHosts.allHosts() {
            host.applyTheme(named: snapshot.themeName)
            host.applySettings(settings)
            host.allowProgramClipboardAccess = allowClipboard
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

    /// The live `FormatString` context for the active workspace/session/tab/pane.
    /// Shared by the status line and `display-message` so both render the same tokens.
    func currentFormatContext() -> FormatContext {
        let workspace = snapshot.activeWorkspace
        let session = workspace?.activeSession
        let tab = workspace?.activeTab
        return FormatContext(
            paneID: activeSurfaceID?.uuidString,
            paneTitle: tab?.title,
            paneCwd: tab?.cwd,
            paneActive: activeSurfaceID != nil,
            paneIndex: nil,
            sessionName: session?.name.isEmpty == false ? session?.name : nil,
            tabName: tab?.title,
            tabIndex: session?.tabs.firstIndex(where: { $0.id == tab?.id }),
            workspaceName: workspace?.name,
            agentKind: tab?.agent?.kind.rawValue,
            agentActivity: tab?.agent?.activity.rawValue,
            gitBranch: tab?.gitBranch,
            clientName: "Harness.app"
        )
    }

    /// Apply a theme. By default this seeds the full editable color set from the
    /// theme preset (overwriting prior color edits) so the whole canvas — terminal
    /// and chrome — adopts the theme. Pass `seedColors: false` for programmatic /
    /// restore paths that must preserve already-resolved colors (e.g. a fresh
    /// config re-import, where the imported config colors must win).
    func setTheme(_ name: String, seedColors: Bool = true) {
        if seedColors {
            let preset = ThemeManager.presetColors(themeName: name)
            settings.customBackgroundHex = preset.backgroundHex
            settings.customForegroundHex = preset.foregroundHex
            settings.customCursorHex = preset.cursorHex
            settings.cursorTextHex = preset.cursorTextHex
            settings.selectionBackgroundHex = preset.selectionBackgroundHex
            settings.selectionForegroundHex = preset.selectionForegroundHex
            settings.boldColorHex = preset.boldHex
            settings.paletteHex = HarnessSettings.normalizedPalette(preset.paletteHex)
            // Chrome accents re-derive from the new theme unless re-set by the user.
            settings.dividerHex = nil
            settings.statusLineHex = nil
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

    /// Select the Nth (0-based) tab — backs the ⌘1–9 tab-switch shortcuts (Ghostty-style).
    /// Out-of-range numbers (e.g. ⌘5 with 3 tabs) are no-ops.
    func selectTab(atIndex index: Int) {
        guard let workspace = snapshot.activeWorkspace,
              index >= 0, index < workspace.tabs.count
        else { return }
        selectTab(workspaceID: workspace.id, tabID: workspace.tabs[index].id)
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
        // last-pane MRU: when the user switches to a different pane *within the same
        // tab*, remember where they came from. Tab switches and remounts (different
        // tab, or a no-op re-set) don't pollute the within-tab history.
        if let old = activeSurfaceID, let new = surfaceID, old != new,
           let oldTab = tabID(forSurface: old), oldTab == tabID(forSurface: new) {
            lastActiveSurfaceID = old
        }
        activeSurfaceID = surfaceID
        // Refresh `window-style`/`pane-style` before the border toggle so each host has the
        // current base before it re-resolves active vs inactive on the focus change.
        refreshPaneStyles()
        let showBorder = surfaceID.map { paneCount(forSurface: $0) > 1 } ?? false
        for host in terminalHosts.allHosts() {
            host.showsActiveBorder = showBorder && host.surfaceID == surfaceID
        }
        // pane-border labels re-evaluate per host (active state just changed above).
        refreshPaneBorders()
        // Push focus to the daemon (single source of truth) so other clients —
        // attach-window compositors, target-less CLI commands — agree on the active
        // pane. Suppressed while reflecting a remote change to avoid a feedback loop.
        if !suppressActivePaneSync, let surfaceID, let loc = tabAndPane(forSurface: surfaceID) {
            _ = requestDaemon(.selectPane(tabID: loc.tabID, paneID: loc.paneID))
        }
    }

    /// Read the `window-style`/`pane-style` options (fresh from the daemon-authored
    /// `options.json`, so a CLI `set-option` lands without an app restart) and push the
    /// resolved set to every host. Each host dims itself when inactive via its own
    /// `showsActiveBorder`. Called on focus changes — the moment dimming matters.
    func refreshPaneStyles() {
        let opts = OptionStore()
        func value(_ key: String) -> String { opts.get(key, scope: .global)?.stringValue ?? "" }
        let styles = PaneStyleSet(
            window: value("window-style"),
            windowActive: value("window-active-style"),
            pane: value("pane-style"),
            paneActive: value("pane-active-style")
        )
        for host in terminalHosts.allHosts() { host.applyPaneStyles(styles) }
    }

    /// Evaluate `pane-border-format` per host and push the label (or hide it when
    /// `pane-border-status off`). Read fresh from the daemon-authored `options.json`.
    func refreshPaneBorders() {
        let opts = OptionStore()
        let status = PaneBorderStatus(option: opts.get("pane-border-status", scope: .global)?.stringValue ?? "off")
        let atTop = status == .top
        let format = opts.get("pane-border-format", scope: .global)?.stringValue ?? ""
        for host in terminalHosts.allHosts() {
            if status == .off || format.isEmpty {
                host.setPaneBorderLabel(nil, atTop: atTop)
            } else {
                let label = FormatString.evaluate(format, context: paneBorderContext(forSurface: host.surfaceID))
                host.setPaneBorderLabel(label, atTop: atTop)
            }
        }
    }

    /// Format context for a specific pane (for `pane-border-format`): its index in the owning
    /// tab's pane order, the tab title (Harness has no per-pane title), and active state.
    private func paneBorderContext(forSurface surfaceID: SurfaceID) -> FormatContext {
        var owningTab: Tab?
        var paneIndex: Int?
        outer: for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if let idx = tab.rootPane.allSurfaceIDs().firstIndex(of: surfaceID) {
                        owningTab = tab; paneIndex = idx; break outer
                    }
                }
            }
        }
        return FormatContext(
            paneID: surfaceID.uuidString,
            paneTitle: owningTab?.title,
            paneCwd: owningTab?.cwd,
            paneActive: surfaceID == activeSurfaceID,
            paneIndex: paneIndex,
            tabName: owningTab?.title,
            workspaceName: snapshot.activeWorkspace?.name,
            agentKind: owningTab?.agent?.kind.rawValue,
            gitBranch: owningTab?.gitBranch,
            clientName: "Harness.app"
        )
    }

    /// Resolve the owning tab + pane IDs for a surface, for daemon focus sync.
    private func tabAndPane(forSurface surfaceID: SurfaceID) -> (tabID: TabID, paneID: PaneID)? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if let pane = paneID(for: surfaceID, in: tab.rootPane) {
                        return (tab.id, pane)
                    }
                }
            }
        }
        return nil
    }

    /// Reflect the daemon's authoritative `activePaneID` (e.g. changed by another
    /// client) into local focus, without echoing the change back to the daemon.
    private func reflectRemoteActivePane() {
        guard let tab = snapshot.activeWorkspace?.activeTab,
              let paneID = tab.activePaneID,
              let surfaceID = surfaceID(forPaneID: paneID, in: tab.rootPane),
              surfaceID != activeSurfaceID
        else { return }
        suppressActivePaneSync = true
        setActiveSurface(surfaceID)
        suppressActivePaneSync = false
    }

    /// Surface backing a pane within a node (inverse of `paneID(for:in:)`).
    private func surfaceID(forPaneID paneID: PaneID, in node: PaneNode) -> SurfaceID? {
        switch node {
        case let .leaf(leaf): return leaf.id == paneID ? leaf.surfaceID : nil
        case let .branch(_, _, first, second):
            return surfaceID(forPaneID: paneID, in: first) ?? surfaceID(forPaneID: paneID, in: second)
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

    /// The tab that owns `surfaceID`, if any.
    private func tabID(forSurface surfaceID: SurfaceID) -> TabID? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                    return tab.id
                }
            }
        }
        return nil
    }

    /// Jump to the most-recently-active pane in the current tab (`select-pane -l`).
    /// No-op if there's no remembered pane still present in this tab.
    func selectLastPane() {
        guard let tab = snapshot.activeWorkspace?.activeTab,
              let last = lastActiveSurfaceID,
              tab.rootPane.allSurfaceIDs().contains(last)
        else { return }
        setActiveSurface(last)
        terminalHosts.host(for: last)?.focusTerminal()
    }

    /// Mark/unmark the active pane as the `join-pane` source (`select-pane -m`/`-M`).
    /// Marking a second pane moves the mark; `set: false` clears it.
    func setMarkedPane(_ set: Bool) {
        markedSurfaceID = set ? activeSurfaceID : nil
        for host in terminalHosts.allHosts() {
            host.showsMarkedBorder = host.surfaceID == markedSurfaceID
        }
    }

    /// Re-assert the marked border after a pane remount (called from the content
    /// mount path alongside `ensureActivePane`).
    func reassertMarkedPane() {
        for host in terminalHosts.allHosts() {
            host.showsMarkedBorder = markedSurfaceID != nil && host.surfaceID == markedSurfaceID
        }
    }

    /// `display-panes`: overlay a number on each pane of the active tab; the digit
    /// the user presses jumps to that pane.
    func showDisplayPanes() {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        let surfaces = tab.rootPane.allSurfaceIDs()
        let panes = surfaces.enumerated().compactMap { index, sid -> (number: Int, host: TerminalHostView)? in
            guard let host = terminalHosts.host(for: sid) else { return nil }
            return (number: index, host: host)
        }
        DisplayPanesOverlay.shared.show(panes: panes) { [weak self] surfaceID in
            self?.setActiveSurface(surfaceID)
            self?.terminalHosts.host(for: surfaceID)?.focusTerminal()
        }
    }

    /// `synchronize-panes`: toggle (or set) input mirroring across all panes of the
    /// active tab. `on == nil` toggles.
    func setSynchronizePanes(_ on: Bool?) {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        let nowOn = on ?? !synchronizedTabIDs.contains(tab.id)
        if nowOn { synchronizedTabIDs.insert(tab.id) } else { synchronizedTabIDs.remove(tab.id) }
        refreshSyncSiblings()
        DisplayMessage.show(nowOn ? "synchronize-panes: on" : "synchronize-panes: off")
    }

    /// Push each live host its sibling surface ids when its tab is synchronized
    /// (and clears them otherwise). Called on toggle and after every structure sync.
    func refreshSyncSiblings() {
        let liveTabIDs = Set(snapshot.workspaces.flatMap { $0.sessions.flatMap { $0.tabs.map(\.id) } })
        synchronizedTabIDs.formIntersection(liveTabIDs)
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    let surfaceIDs = tab.rootPane.allSurfaceIDs()
                    let synced = synchronizedTabIDs.contains(tab.id) && surfaceIDs.count > 1
                    for sid in surfaceIDs {
                        guard let host = terminalHosts.host(for: sid) else { continue }
                        host.setSyncSiblings(synced ? surfaceIDs.filter { $0 != sid }.map(\.uuidString) : [])
                    }
                }
            }
        }
    }

    /// Join the marked pane into the active pane as a split (`join-pane`). The
    /// marked pane becomes a new split alongside the active pane, then the mark
    /// clears. No-op (with a toast) if nothing is marked or the mark is gone.
    func joinMarkedPane(direction: SplitDirection) {
        guard let markedSurface = markedSurfaceID,
              let tab = snapshot.activeWorkspace?.activeTab,
              let activeSurface = activeSurfaceID,
              let destPane = paneID(for: activeSurface, in: tab.rootPane)
        else { DisplayMessage.show("join-pane: no marked pane"); return }
        // The marked pane can live in any tab; find its pane id across the snapshot.
        let sourcePane = snapshot.workspaces
            .flatMap(\.sessions).flatMap(\.tabs)
            .compactMap { paneID(for: markedSurface, in: $0.rootPane) }
            .first
        guard let sourcePane, sourcePane != destPane else {
            DisplayMessage.show("join-pane: invalid mark")
            return
        }
        _ = requestDaemon(.joinPane(sourcePaneID: sourcePane, destPaneID: destPane, direction: direction))
        setMarkedPane(false)
        syncFromDaemon()
    }

    /// Re-assert the active-pane border after a (re)mount of `tab`'s panes. If the
    /// tracked active surface isn't part of this tab, fall back to its first pane so
    /// a freshly shown tab always has a clearly focused pane.
    func ensureActivePane(for tab: Tab) {
        let surfaces = tab.rootPane.allSurfaceIDs()
        guard !surfaces.isEmpty else { return }
        let target = activeSurfaceID.flatMap { surfaces.contains($0) ? $0 : nil } ?? surfaces.first
        setActiveSurface(target)
        // Focus the active pane's terminal so typing + copy/paste target it immediately.
        // Reused host views don't re-fire `viewDidMoveToWindow`, so this mount path (run on
        // every tab/pane switch) must re-assert first responder explicitly — otherwise the
        // first responder can linger on the previous tab's view and ⌘C/⌘V miss.
        if let target { terminalHosts.host(for: target)?.focusTerminal() }
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

    /// Toggle the in-pane copy-mode overlay on the active pane. The native surface owns the
    /// scrollback and drives the shared `CopyModeReducer`, so no daemon text capture is needed.
    func toggleCopyMode() {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return }
        if host.isInCopyMode {
            host.exitCopyMode()
        } else {
            let modeKeys = HarnessOptions.shared.get("mode-keys", scope: .global)?.stringValue ?? "vi"
            host.enterCopyMode(modeKeys: modeKeys)
        }
    }

    /// Forward a `copy-mode -X` action (from the `:` prompt / `send-keys -X`) to the active pane.
    func performCopyModeAction(_ action: CopyModeAction) {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return }
        host.performCopyModeAction(action)
    }

    /// Release the active pane to headless: drop this client's output subscription + size vote so
    /// the PTY keeps running (and can grow to other clients), then re-grab with
    /// `reattachActiveSurface()`. Routed through the host — the daemon's per-client detach acts on
    /// the subscribing connection, which an ephemeral RPC socket is not.
    func detachActiveSurface() {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return }
        host.detachFromDaemonSurface()
    }

    /// Re-grab a surface released with `detachActiveSurface()`: resubscribe and replay scrollback.
    func reattachActiveSurface() {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return }
        host.reattachToDaemonSurface()
    }

    /// True when the active pane has been released from the daemon (its detach overlay is up) —
    /// drives Detach/Reattach menu-item enablement.
    var activePaneIsDetached: Bool {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return false }
        return host.isDetachedFromDaemon
    }

    /// Scroll the active pane's viewport to the previous OSC 133 shell prompt (no-op without marks).
    func jumpToPreviousPrompt() {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return }
        host.jumpToPreviousPrompt()
    }

    /// Scroll the active pane's viewport to the next OSC 133 shell prompt (no-op without marks).
    func jumpToNextPrompt() {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return }
        host.jumpToNextPrompt()
    }

    func selectWorkspace(byIndex index: Int) {
        guard index >= 0, index < snapshot.workspaces.count else { return }
        selectWorkspace(snapshot.workspaces[index].id)
    }

    func beginRenameActiveTab() {
        NotificationCenter.default.post(name: NotificationBus.shared.snapshotChanged, object: nil, userInfo: ["beginRenameActiveTab": true])
    }

    func reimportTerminalConfig() {
        if let imported = TerminalConfigImporter.load() {
            settings = HarnessSettings.makeDefaults(imported: imported)
            try? settings.save()
            // Colors were just seeded from the imported terminal config above;
            // don't let the theme preset overwrite the user's explicit config.
            if let theme = imported.themeName {
                setTheme(theme, seedColors: false)
            } else {
                setTheme(ThemeManager.defaultDisplayName, seedColors: false)
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
        host.applyTheme(named: snapshot.themeName)
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

    /// Every running agent (one row per tab carrying a detected agent), waiting
    /// agents first, for the Agent Inbox panel. Reuses `SessionEditor.listAgents()`
    /// so the GUI and CLI derive the exact same view from the snapshot.
    func agentsList() -> [AgentSessionSummary] {
        SessionEditor(snapshot: snapshot).listAgents()
            .sorted { lhs, rhs in
                if lhs.waiting != rhs.waiting { return lhs.waiting }   // waiting first
                return lhs.lastActivityAt > rhs.lastActivityAt          // most recent next
            }
    }

    /// Jump to the tab backing an agent row (Agent Inbox). Mirrors
    /// `openNotification` but does not clear the notification — viewing the agent
    /// list shouldn't dismiss a pending alert.
    func openAgent(_ agent: AgentSessionSummary) {
        guard let workspace = snapshot.workspaces.first(where: { ws in
            ws.sessions.contains { $0.id == agent.sessionID }
        }) else { return }
        selectWorkspace(workspace.id)
        selectTab(workspaceID: workspace.id, tabID: agent.tabID)
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
        let key = "\(surfaceID.uuidString)|\(body)"
        // Already pinged for this exact surface+message and it's still pending: just re-assert the
        // ring and return. A program spamming the bell (body is the constant "Bell") would
        // otherwise drive a full daemon notify + snapshot round-trip per `\a` on the main thread.
        // The key is cleared once the tab stops being `.waiting` (see `pushNewRemoteNotifications`),
        // so a genuinely new alert after dismissal still fires.
        guard !pushedNotificationKeys.contains(key) else {
            terminalHosts.host(for: surfaceID)?.showsWaitingRing = true
            return
        }
        requestDaemon(.notify(
            surfaceID: surfaceID.uuidString,
            title: title,
            body: body
        ))
        pushedNotificationKeys.insert(key)
        terminalHosts.host(for: surfaceID)?.showsWaitingRing = true
        if NSApp.isActive == false {
            deliverAgentAlert(title: title, body: body)
        }
        syncFromDaemon()
    }

    func clearNotification(for surfaceID: SurfaceID) {
        requestDaemon(.clearNotification(surfaceID: surfaceID.uuidString))
        terminalHosts.host(for: surfaceID)?.showsWaitingRing = false
        syncFromDaemon()
    }

    func updateFontSize(delta: Float) {
        applyFontSize(settings.fontSize + delta)
    }

    /// ⌘0 — restore the default font size (Ghostty parity, completes the ⌘+/⌘-/⌘0 trio).
    func resetFontSize() {
        applyFontSize(HarnessSettings().fontSize)
    }

    private func applyFontSize(_ size: Float) {
        settings.fontSize = max(8, min(32, size))
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

    private var lastDaemonErrorNotice: Date?

    @discardableResult
    func requestDaemon(_ request: IPCRequest) -> IPCResponse? {
        do {
            return try daemon.request(request)
        } catch {
            // Never block the UI with a modal: a transient miss (e.g. the daemon
            // is still spawning at launch) must degrade gracefully. Log always,
            // and surface a non-blocking, throttled toast so the user isn't left
            // wondering — but the app keeps running and self-heals on the next sync.
            fputs("Harness daemon request failed: \(error)\n", stderr)
            noteDaemonError(error)
            return nil
        }
    }

    /// A throttled, non-blocking notice that the daemon is unreachable.
    func noteDaemonError(_ error: Error) {
        let now = Date()
        if let last = lastDaemonErrorNotice, now.timeIntervalSince(last) < 8 { return }
        lastDaemonErrorNotice = now
        guard let host = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView else { return }
        Toast.show("Reconnecting to HarnessDaemon…", in: host)
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
        // loop when the renderer already told us about the same path.
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
    /// time; subsequent calls are no-ops, so it's safe to call eagerly. Also
    /// installs the foreground-presentation delegate (see `ForegroundPresenter`).
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        // Without a delegate that opts in, macOS suppresses banners while Harness is
        // the *frontmost* app — so an agent notification fired while you're looking at
        // another tab would silently no-op. The presenter forces banner + sound + list
        // even in the foreground, so agent alerts always land.
        center.delegate = ForegroundPresenter.shared
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func show(title: String, body: String, withSound: Bool = true) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = withSound ? .default : nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// The current system authorization status, on the main actor — drives the Settings
    /// permission indicator so the user can tell whether macOS is allowing alerts at all.
    static func authorizationStatus(_ completion: @escaping @MainActor (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(status) } }
        }
    }

    /// Drive the permission flow from a user action: prompt when undecided, or open System
    /// Settings ▸ Notifications when macOS has already denied us (the system never re-prompts
    /// after a denial, so the only path back is the settings pane).
    static func requestOrOpenSettings() {
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .denied:
                DispatchQueue.main.async { openSystemNotificationSettings() }
            default:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if !granted {
                        DispatchQueue.main.async { openSystemNotificationSettings() }
                    }
                }
            }
        }
    }

    static func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Fire a one-off banner so the user can confirm delivery end-to-end (bypasses the
    /// agent-activity gates; still honors the system permission). If permission isn't granted
    /// yet, request/route it first so the test isn't a silent no-op.
    static func sendTest() {
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                switch status {
                case .authorized, .provisional:
                    show(title: "Harness", body: "Test notification — alerts are working.", withSound: true)
                case .denied:
                    openSystemNotificationSettings()
                default:
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                        DispatchQueue.main.async {
                            if granted {
                                show(title: "Harness", body: "Test notification — alerts are working.", withSound: true)
                            } else {
                                openSystemNotificationSettings()
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Presents agent notifications as banners even when Harness is frontmost (the OS
/// default is to swallow them). Retained for the process lifetime as the UN delegate.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ForegroundPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
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
