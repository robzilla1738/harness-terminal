import AppKit
import Foundation
import HarnessCore
import HarnessTerminalEngine
import HarnessTerminalKit
import HarnessTheme
import UserNotifications

@MainActor
final class SessionCoordinator: NSObject {
    static let shared = SessionCoordinator()

    private let daemon = DaemonSessionService()
    private(set) var snapshot = SessionSnapshot()
    private var lastRevision = -1
    private let terminalHosts = TerminalPaneRegistry()
    /// Event-driven branch labels: watches each repository's `HEAD` and pushes
    /// `updateTabGitBranch` only on real change (replaced the 2 s git-subprocess poll).
    private let gitBranchMonitor = GitBranchMonitor()
    /// Long-lived push channel: the daemon sends every committed revision, the handler
    /// syncs when it differs from `lastRevision`. This is how external structure changes
    /// (`harness-cli split-pane` against a GUI session) reach the app now that the
    /// 2 s metadata poll is gone.
    private var snapshotSubscription: DaemonSubscription?
    /// Invalidates stale subscription callbacks: bumped on every (re)subscribe, checked by
    /// the previous subscription's `onEnd` (its `cancel()` fires `onEnd` too — without the
    /// guard, replacing a subscription would schedule a duplicate resubscribe).
    private var snapshotSubscriptionGeneration = 0
    private var snapshotResubscribeDelay: TimeInterval = 1
    /// Push-loss insurance, not the mechanism: the daemon drops subscribers whose write
    /// backlog exceeds its cap, and a dropped fd silently stops pushes. Runs only while
    /// the app is active.
    private var safetyPollTimer: Timer?
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
    /// Hot-reload watchers for `settings.json` / `keybindings.json` (Ghostty config-reload-on-save).
    /// Held for the coordinator's lifetime.
    private var configWatchers: [FileWatcher] = []
    /// Which daemon the GUI currently drives: the local one, or a remote daemon over an SSH tunnel.
    /// New terminal panes are bound to this endpoint, and `daemon` (session/layout IPC) tracks it.
    private(set) var activeEndpoint: Endpoint = .localControlSocket
    var activeSurfaceID: SurfaceID?
    /// Most-recently-active pane within the current tab, for `select-pane -l`
    /// (last-pane). Updated only on genuine intra-tab pane switches.
    private(set) var lastActiveSurfaceID: SurfaceID?
    /// Set while reflecting the daemon's `activePaneID` into local focus, so the
    /// `setActiveSurface` push doesn't echo back to the daemon (feedback loop).
    private var suppressActivePaneSync = false
    /// The marked pane (`select-pane -m`) — implicit source for `join-pane`.
    private(set) var markedSurfaceID: SurfaceID?
    /// Last finished command's duration per pane (OSC 133 C→D, via the host delegate) — feeds
    /// `#{command_duration}`. GUI vantage only; entries die with the process (never persisted).
    private var lastCommandDurations: [SurfaceID: TimeInterval] = [:]
    /// Tabs with `synchronize-panes` on — input typed in any pane mirrors to all.
    private var synchronizedTabIDs: Set<TabID> = []
    var structureRevision = 0

    /// The most recently closed tab's directory + title, captured so ⇧⌘T can
    /// reopen a fresh tab in the same place. Holds only the last one (the common
    /// "undo an accidental close" case); the underlying pty is gone, so this
    /// spawns a new shell rather than resurrecting the process.
    private var lastClosedTab: (cwd: String, title: String)?

    /// The active tab's live working directory (kept current by `SurfaceShellTracker`),
    /// used as the default for new tabs/sessions so they open where the user is
    /// working — matching Terminal.app / iTerm. `nil` when unknown.
    private var activeTabCWD: String? {
        // `window-inherit-cwd` (default on): off pins new tabs/sessions to `defaultCWD`
        // by making the inherited value resolve to nil at every consumer.
        guard settings.windowInheritCWD,
              let cwd = snapshot.activeWorkspace?.activeTab?.cwd, !cwd.isEmpty else { return nil }
        return cwd
    }

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
        // Deliberately do NOT hydrate from the daemon here. This singleton is first
        // touched while building the window (before `showWindow`), and `syncFromDaemon`
        // is a blocking daemon IPC — doing it here freezes first paint on a cold/slow
        // daemon. We start from the default `snapshot` + already-loaded local `settings`
        // (chrome resolves correctly from `settings.custom*Hex`), and the async
        // `DaemonLauncher.ensureRunning` callback in AppDelegate performs the first
        // hydration the moment the daemon answers — after the window is on screen.
        observeNotifications()
        configureGitBranchMonitor()
        observeAppActivation()
        startSafetyPoll()
        startConfigWatchers()
    }

    /// Watch the on-disk config so an external edit (a text editor, `harness-cli set-option`, a
    /// dotfile sync) applies live — Ghostty's config-reload-on-save. The `fresh != settings` guard
    /// makes the app's OWN saves a no-op: it already updated the in-memory `settings` before writing,
    /// so the reload loads identical values and does nothing. `FileWatcher` delivers on the main
    /// queue, so `assumeIsolated` is safe (and hop-free) for this @MainActor coordinator.
    private func startConfigWatchers() {
        let settingsWatcher = FileWatcher(url: HarnessPaths.settingsURL) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fresh = HarnessSettings.load()
                guard fresh != self.settings else { return }
                self.settings = fresh
                self.applySettingsToHosts()
                // An external toggle of `secureKeyboardEntry` must re-sync the process-global
                // secure-input lock, exactly as `setSecureKeyboardEntry` does — otherwise the
                // lock can stay held after the setting is turned off via an editor / harness-cli.
                SecureKeyboardEntry.shared.settingChanged()
            }
        }
        let keybindingsWatcher = FileWatcher(url: KeybindingsStore.fileURL) { [weak self] in
            MainActor.assumeIsolated {
                guard self != nil else { return }
                KeybindingsService.shared.reload()
            }
        }
        configWatchers = [settingsWatcher, keybindingsWatcher]
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
        guard note.userInfo?["notification"] is AgentNotification else { return }
        NotificationCenter.default.post(name: NotificationBus.shared.tabStatusChanged, object: nil)
    }

    /// Hydrate from the daemon's snapshot. Returns whether the fetch succeeded so launch-time callers
    /// can gate work (e.g. draining queued external opens) on a real hydration rather than guessing.
    // MARK: - Remote daemons

    /// Point the GUI at a saved remote daemon: bring up its SSH tunnel (off-main, it blocks), then
    /// switch the session service + new panes to that endpoint and rehydrate from it. On failure we
    /// surface a throttled error and stay on the current daemon.
    func connectToRemote(named name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Bringing up the SSH tunnel blocks (spawns ssh + waits for the remote daemon), so it
            // runs off-main. Carry Sendable values (an endpoint or an error message — not a
            // non-Sendable Error) back to the main actor.
            var resolved: Endpoint?
            var failureMessage: String?
            do {
                resolved = try RemoteHostsService.shared.connect(named: name)
            } catch {
                failureMessage = "\(error)"
            }
            let endpoint = resolved
            let message = failureMessage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let endpoint {
                        self.applyEndpointSwitch(endpoint)
                    } else {
                        self.noteDaemonError(DaemonSessionError.daemonError(message ?? "connection failed"))
                    }
                }
            }
        }
    }

    /// Tear down the remote tunnel and return the GUI to the local daemon.
    func disconnectRemote() {
        RemoteHostsService.shared.disconnect()
        applyEndpointSwitch(.localControlSocket)
    }

    /// Repoint everything at `endpoint`: the session-service IPC, future panes, and the live view.
    /// Existing panes are dropped (they belonged to the old daemon and have different surface IDs on
    /// the new one) so the next layout pass rebuilds them against the new endpoint.
    private func applyEndpointSwitch(_ endpoint: Endpoint) {
        activeEndpoint = endpoint
        daemon.switchEndpoint(endpoint)
        terminalHosts.prune(keeping: [])
        // Re-point the push channel: the old subscription is pinned to the old daemon
        // (its onEnd is invalidated by the generation bump inside). A failed attempt has
        // no onEnd to retry from, so back off explicitly.
        startSnapshotSubscription()
        if snapshotSubscription == nil { scheduleSnapshotResubscribe() }
        _ = syncFromDaemon()
    }

    @discardableResult
    func syncFromDaemon(metadataOnly: Bool = false) -> Bool {
        let remote: SessionSnapshot
        do {
            remote = try daemon.fetchSnapshot()
        } catch {
            // Don't silently no-op: a failed hydration leaves the UI showing stale layout/metadata.
            // Log + throttled toast (`noteDaemonError`); the app self-heals on the next sync.
            fputs("Harness: snapshot fetch failed: \(error)\n", harnessStderr)
            noteDaemonError(error)
            return false
        }
        StartupMetrics.shared.mark(.firstSnapshot) // idempotent: records the first hydration only
        let structureChanged = structureFingerprint(remote) != structureFingerprint(snapshot)
        // A CLI-driven theme change arrives by push (metadata-only), so it must force the
        // chrome path itself — recurring syncs otherwise never rebuild renderers.
        let themeChanged = remote.themeName != snapshot.themeName
        snapshot = remote
        lastRevision = remote.revision
        // The daemon answered: bring up the push channel if it isn't already, and reconcile
        // the branch watchers against the fresh tab set (cheap when nothing moved).
        startSnapshotSubscriptionIfNeeded()
        gitBranchMonitor.update(tabs: gitBranchRecords(from: remote))
        if structureChanged {
            structureRevision += 1
            // Drop hosts for surfaces the daemon no longer knows: killPane / remote closes remount
            // the pane UI but never told the registry, so dead TerminalHostViews (and their Metal
            // surfaces) accumulated for the life of the app. Hosts are only ever registered while
            // building panes from a snapshot, so anything outside the latest snapshot is gone for
            // good — explicit close paths still removeHost() eagerly for the common case.
            let live = Set(remote.workspaces.flatMap { ws in
                ws.sessions.flatMap { session in
                    session.tabs.flatMap { $0.rootPane.allSurfaceIDs() }
                }
            })
            terminalHosts.prune(keeping: live)
        }
        pushNewRemoteNotifications(from: remote)
        pushAgentActivityNotifications(from: remote)
        if !metadataOnly || themeChanged {
            applyThemeToAllHosts()
        }
        updateDockBadge(from: remote)
        reflectRemoteActivePane()
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: [
                "revision": remote.revision,
                "structureChanged": structureChanged,
                "chromeChanged": !metadataOnly || themeChanged,
                "metadataOnly": metadataOnly,
            ]
        )
        return true
    }

    /// Clean-quit reap of ephemeral (Plain-mode, unpinned) sessions. Best-effort but *reliable*: the
    /// daemon can be momentarily busy at quit and a single default-timeout request that drops would
    /// silently leave Plain tabs alive (breaking "quit closes my tabs"). Uses a longer timeout and one
    /// retry, and is bounded so it can never hang process exit. Synchronous — must finish before exit.
    func closeEphemeralSessionsBeforeQuit() {
        for attempt in 0 ..< 2 {
            if (try? daemon.request(.closeEphemeralSessions, timeout: 4)) != nil { return }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.1) } // brief gap before the single retry
        }
        fputs("Harness: closeEphemeralSessions did not confirm before quit\n", harnessStderr)
    }

    private func structureFingerprint(_ snap: SessionSnapshot) -> Int {
        var hasher = Hasher()
        // Include the active workspace/session/tab identity so intra-tab focus changes
        // and tab switches still bump structureRevision (same behaviour as before).
        if let ws = snap.activeWorkspace {
            hasher.combine(ws.id)
            if let session = ws.activeSession {
                hasher.combine(session.id)
                if let tab = session.activeTab { hasher.combine(tab.id) }
            }
        }
        // Walk *all* workspaces/sessions/tabs so a split added to a background tab (e.g.
        // via the CLI) bumps structureRevision even when that tab isn't active.  This mirrors
        // the prune pass at syncFromDaemon which also walks the full set.
        for ws in snap.workspaces {
            for session in ws.sessions {
                for tab in session.tabs {
                    for surface in tab.rootPane.allSurfaceIDs() {
                        hasher.combine(surface)
                    }
                }
            }
        }
        return hasher.finalize()
    }

    private func applyThemeToAllHosts() {
        updateChromeAndHosts()
        // applyThemeToAllHosts is called after a full snapshot sync and needs to adopt
        // any synchronize-panes changes that arrived with the snapshot, rebuild the sibling
        // lists for input mirroring, and re-assert the marked-pane border.
        adoptSynchronizeOptions()
        refreshSyncSiblings()
        reassertMarkedPane()
    }

    private func refreshChromePalette(systemAppearance: HarnessSystemAppearance? = nil) {
        HarnessChrome.update(
            themeName: snapshot.themeName,
            opacity: CGFloat(settings.backgroundOpacity),
            blur: settings.backgroundBlur,
            appearanceMode: settings.appearanceMode,
            systemAppearance: systemAppearance,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            backgroundHex: settings.customBackgroundHex,
            foregroundHex: settings.customForegroundHex,
            cursorHex: settings.customCursorHex
        )
    }

    @discardableResult
    func refreshChromeForEffectiveAppearanceChange(systemAppearance: HarnessSystemAppearance? = nil) -> Bool {
        guard HarnessEffectiveAppearanceRefreshPolicy.shouldRefreshOnEffectiveAppearanceChange(
            appearanceMode: settings.appearanceMode
        ) else {
            return false
        }
        // The flip must re-skin the TERMINAL CANVAS, not just the window chrome: route
        // through the same full host re-apply the settings path uses (theme + appearance
        // + borders per host), or the canvas keeps rendering the pre-flip palette until
        // an unrelated settings change forces a reapply.
        updateChromeAndHosts(systemAppearance: systemAppearance)
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: [
                "revision": snapshot.revision,
                "structureChanged": false,
                "chromeChanged": true,
                "metadataOnly": true,
            ]
        )
        return true
    }

    /// Push the current `terminal-identity` option to a host so its XTVERSION / secondary-DA
    /// replies match the `TERM_PROGRAM` the daemon exports (single source: `options.json`).
    private func applyTerminalIdentity(to host: TerminalHostView) {
        let spec = TerminalIdentity.spec(forOption: HarnessOptions.shared.get(TerminalIdentity.optionKey)?.stringValue)
        host.setTerminalIdentity(name: spec.name, version: spec.version, daVersion: spec.daVersion)
    }

    /// Push the theme's focus-ring / waiting colors into a host (the terminal package
    /// can't reach the app palette, so the app owns these indicator colors).
    private func pushBorderColors(to host: TerminalHostView) {
        let chrome = HarnessChrome.current
        host.applyBorderColors(
            active: chrome.focusRing,
            waiting: chrome.waiting
        )
    }

    // syncWaitingRings() was removed: the function iterated all hosts × all tabs with a
    // completely empty `if let match` body — it found the owning tab for each host but then
    // did nothing with it.  Searching the codebase for "waiting ring", "waitingRing", and
    // "ring" found no TerminalHostView API to call (the border colours are pushed once via
    // pushBorderColors; there is no per-tab waiting-ring toggle on the host).  The only live
    // call site was in syncFromDaemon, which is updated below to remove the call.  If a
    // per-host waiting indicator is needed in the future, add an `applyWaiting(_:)` API to
    // TerminalHostView and re-introduce the loop at that point.

    private func pushNewRemoteNotifications(from snapshot: SessionSnapshot) {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.status == .waiting {
                    guard let text = tab.notificationText, !text.isEmpty,
                          let surfaceID = tab.rootPane.allSurfaceIDs().first
                    else { continue }
                    let key = "\(surfaceID.uuidString)|\(text)"
                    guard !pushedNotificationKeys.contains(key) else { continue }
                    // Gate on the per-event preference *before* marking the key pushed, so toggling
                    // "Agent needs input" off then back on during the same waiting episode still
                    // fires once — a disabled event must not consume the dedup key. (Same reason as
                    // the watched-pane deferral below: don't mark pushed when we aren't delivering.)
                    guard settings.isEventEnabled(.agentWaiting) else { continue }
                    // Always surface the waiting ring; but don't fire a banner for the pane you're
                    // actively watching — its output + the ring already show it. Defer (don't mark
                    // pushed) so it still fires once you look away, matching the activity path.
                    if NSApp.isActive, surfaceID == activeSurfaceID { continue }
                    pushedNotificationKeys.insert(key)
                    let agentLabel = effectiveAgentKind(for: tab)?.displayName ?? "Harness"
                    let title = "\(agentLabel) · \(tab.title.isEmpty ? "Terminal" : tab.title)"
                    deliverAgentAlert(event: .agentWaiting, title: title, body: text)
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
                    // Gate on the per-event preference *before* the cooldown, so a disabled
                    // "Agent finished" doesn't arm the 30s window and suppress a later
                    // (re-enabled) stop. `lastAgentActivity` above still tracks the edge.
                    guard settings.isEventEnabled(.agentFinished) else { continue }
                    // Cooldown so a flapping stream can't spam.
                    if let last = lastStopNotifyAt[key], Date().timeIntervalSince(last) < 30 { continue }
                    lastStopNotifyAt[key] = Date()

                    let folder = HarnessDesign.pathDisplayName(tab.cwd)
                    let title = "\(agent.kind.displayName) · \(folder)"
                    deliverAgentAlert(event: .agentFinished, title: title, body: "Finished — waiting for you")
                }
            }
        }
        lastAgentActivity = lastAgentActivity.filter { live.contains($0.key) }
        lastStopNotifyAt = lastStopNotifyAt.filter { live.contains($0.key) }
    }

    /// Single delivery point for agent alerts. First gates on the per-event "which events
    /// notify me" choice (`isEventEnabled`); then honors the two delivery toggles:
    /// `systemNotificationsEnabled` (push banner) and `notificationSoundEnabled` (chime).
    /// Banner-on carries the sound; banner-off-but-chime-on still plays an in-app chime,
    /// so an enabled event is audible even when banners are suppressed.
    private func deliverAgentAlert(event: NotificationEvent, title: String, body: String) {
        guard settings.isEventEnabled(event) else { return }
        let wantBanner = settings.systemNotificationsEnabled
        let wantChime = settings.notificationSoundEnabled
        guard wantBanner || wantChime else { return }
        if wantBanner {
            DesktopNotifier.show(title: title, body: body, withSound: wantChime)
        } else if wantChime {
            NSSound(named: "Glass")?.play()
        }
    }

    private func effectiveAgentKind(for tab: Tab) -> AgentKind? {
        tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title)
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
        updateChromeAndHosts()
        // applySettingsToHosts does NOT call adoptSynchronizeOptions / refreshSyncSiblings /
        // reassertMarkedPane because it runs on pure settings changes (font, opacity, colours)
        // that cannot affect the synchronize-panes or marked-pane state.  A post below notifies
        // chrome consumers (window, sidebar, status line) so they repaint with the new palette.
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

    /// Shared per-host update loop: refresh the global chrome palette and push the current
    /// theme + settings + identity + border colours to every live terminal host.
    /// Called by both `applyThemeToAllHosts` and `applySettingsToHosts`; each caller adds
    /// its own divergent extras after this returns. Chrome goes through the appearance-aware
    /// `refreshChromePalette()` so `.macOSSystem` resolution applies on every path.
    private func updateChromeAndHosts(systemAppearance: HarnessSystemAppearance? = nil) {
        refreshChromePalette(systemAppearance: systemAppearance)
        let allowClipboard = HarnessOptions.shared.get("set-clipboard")?.boolValue ?? true
        for host in terminalHosts.allHosts() {
            host.applyTheme(named: snapshot.themeName)
            host.applySettings(settings)
            host.allowProgramClipboardAccess = allowClipboard
            applyTerminalIdentity(to: host)
            pushBorderColors(to: host)
        }
    }

    /// The live `FormatString` context for the active workspace/session/tab/pane.
    /// Shared by the status line and `display-message` so both render the same tokens.
    func currentFormatContext() -> FormatContext {
        let workspace = snapshot.activeWorkspace
        let session = workspace?.activeSession
        let tab = workspace?.activeTab
        var context = FormatContext(
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
        // Extended tmux-parity fields derivable from the snapshot (PTY-backed values —
        // pane_pid, pane_width, history_bytes — are daemon vantage; left nil here).
        context.paneCurrentCommand = tab?.currentCommand
        context.paneDead = tab.map { $0.exitStatus != nil }
        context.paneExitStatus = tab?.exitStatus
        context.sessionID = session?.id.uuidString
        context.windowID = tab?.id.uuidString
        context.sessionWindows = session?.tabs.count
        context.windowPanes = tab?.rootPane.allPaneIDs().count
        if let tab, let session { context.windowActive = tab.id == session.activeTabID }
        context.sessionGroup = session.flatMap { snapshot.groupName(of: $0) }
        // Same expression as the daemon's builder so `#{window_flags}` agrees between
        // GUI display-message and CLI/hook output.
        context.windowFlags = tab.map { ($0.zoomedPaneID != nil ? "Z" : "") + $0.alertFlags }
        // GUI vantage: OSC 133 command timing arrives via the host delegate, not the snapshot.
        context.commandDurationSeconds = activeSurfaceID.flatMap { lastCommandDurations[$0] }
        return context
    }

    /// Apply a theme. By default this seeds the full editable color set from the
    /// theme preset (overwriting prior color edits) so the whole canvas — terminal
    /// and chrome — adopts the theme. Pass `seedColors: false` for programmatic /
    /// restore paths that must preserve already-resolved colors (e.g. a fresh
    /// config re-import, where the imported config colors must win).
    func setTheme(_ name: String, seedColors: Bool = true) {
        if seedColors {
            settings.clearThemeColorOverrides()
            try? settings.save()
        }
        requestDaemon(.setTheme(name: name))
        syncFromDaemon()
    }

    /// Apply an imported `.harnesstheme` document. Custom themes aren't in the static catalog,
    /// so the colors are seeded straight from the document (not resolved by name like `setTheme`).
    /// Any appearance knobs the document carries (opacity/blur/font/padding/terminal-output sync)
    /// are applied too; absent keys leave the current setting untouched. `themeName` is set on the
    /// daemon so the canvas + chrome adopt the imported name.
    func applyImportedTheme(_ document: ThemeDocument) {
        let colors = document.colors
        settings.customBackgroundHex = colors.background.hexString
        settings.customForegroundHex = colors.foreground.hexString
        settings.customCursorHex = colors.cursor?.hexString
        settings.cursorTextHex = colors.cursorText?.hexString
        settings.selectionBackgroundHex = colors.selectionBackground?.hexString
        settings.selectionForegroundHex = colors.selectionForeground?.hexString
        settings.boldColorHex = colors.bold?.hexString
        settings.paletteHex = HarnessSettings.normalizedPalette(colors.palette.map { $0.hexString })
        // Chrome accents re-derive from the imported colors unless re-set by the user.
        settings.dividerHex = nil
        settings.statusLineHex = nil
        if let appearance = document.appearance {
            if let opacity = appearance.backgroundOpacity {
                settings.backgroundOpacity = HarnessSettings.clampedOpacity(Float(opacity))
            }
            if let blur = appearance.backgroundBlur {
                settings.backgroundBlur = HarnessSettings.clampedBlur(blur)
            }
            if let family = appearance.fontFamily, !family.isEmpty {
                settings.fontFamily = family
            }
            if let size = appearance.fontSize {
                settings.fontSize = HarnessSettings.clampedFontSize(Float(size))
            }
            if let px = appearance.windowPaddingX {
                settings.windowPaddingX = HarnessSettings.clampedPadding(Float(px))
            }
            if let py = appearance.windowPaddingY {
                settings.windowPaddingY = HarnessSettings.clampedPadding(Float(py))
            }
            if let applyToOutput = appearance.applyToTerminalOutput {
                settings.applyThemeToTerminalOutput = applyToOutput
            }
        }
        try? settings.save()
        requestDaemon(.setTheme(name: document.name))
        syncFromDaemon()
    }

    func addWorkspace(name: String) {
        requestDaemon(.newWorkspace(name: name))
        syncFromDaemon()
    }

    func addSession(to workspaceID: WorkspaceID, cwd: String? = nil, name: String? = nil) {
        requestDaemon(.newSession(workspaceID: workspaceID, cwd: cwd ?? activeTabCWD ?? settings.defaultCWD, name: name, shell: settings.defaultShell))
        syncFromDaemon()
        // Kick the cwd tracker immediately after session creation so the shell's working
        // directory lights up as early as possible.  A second kick follows the daemon's next
        // snapshotChanged notification (which arrives once the PTY/surface is live), so there
        // is no fixed timing dependency — the notification-driven path handles the "shell not
        // yet spawned" window without a magic timeout.
        SurfaceShellTracker.shared.bumpScan()
    }

    func addTab(to workspaceID: WorkspaceID, cwd: String? = nil) {
        requestDaemon(.newTab(workspaceID: workspaceID, cwd: cwd ?? activeTabCWD ?? settings.defaultCWD, shell: settings.defaultShell))
        syncFromDaemon()
        // Kick the cwd tracker immediately so the new tab's path lights up without waiting
        // for the next 500ms tick.  When the daemon posts snapshotChanged for the new PTY
        // surface, syncFromDaemon is called again and SurfaceShellTracker's next tick picks
        // up the final cwd — removing the need for an additional 300ms delayed kick.
        SurfaceShellTracker.shared.bumpScan()
    }

    func openDefaultTerminalLaunch(_ launch: DefaultTerminalLaunchRequest) {
        guard let workspaceID = snapshot.activeWorkspace?.id ?? snapshot.workspaces.first?.id else { return }
        let cwd = launch.cwd ?? settings.defaultCWD
        guard case let .tabID(tabID)? = requestDaemon(.newTab(workspaceID: workspaceID, cwd: cwd, shell: settings.defaultShell)) else {
            syncFromDaemon()
            return
        }
        if let title = launch.title, !title.isEmpty {
            requestDaemon(.renameTab(tabID: tabID, name: title))
        }
        syncFromDaemon()
        guard let surfaceID = firstSurfaceID(forTab: tabID) else { return }
        setActiveSurface(surfaceID)
        terminalHosts.host(for: surfaceID)?.focusTerminal()
        if let command = launch.command, !command.isEmpty {
            requestDaemon(.sendData(surfaceID: surfaceID.uuidString, data: Data((command + "\r").utf8)))
        }
    }

    func splitActivePane(direction: SplitDirection) {
        guard let workspace = snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let paneID = activeSurfaceID.flatMap({ paneID(for: $0, in: tab.rootPane) })
                ?? tab.rootPane.allPaneIDs().last
        else { return }
        requestDaemon(.newSplit(tabID: tab.id, paneID: paneID, direction: direction, shell: settings.defaultShell))
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

    private func firstSurfaceID(forTab tabID: TabID) -> SurfaceID? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                if let tab = session.tabs.first(where: { $0.id == tabID }) {
                    return tab.rootPane.allSurfaceIDs().first
                }
            }
        }
        return nil
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

    /// Select the Nth (0-based) tab — backs the ⌘1–9 tab-switch shortcuts.
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

    private func rememberTabForReopen(_ tab: Tab) {
        lastClosedTab = (cwd: tab.cwd, title: tab.title)
    }

    private func closeActiveTabOnly() {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        // Remember where this tab lived so ⇧⌘T can reopen a shell there.
        rememberTabForReopen(tab)
        let surfaces = tab.rootPane.allSurfaceIDs()
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemon(.closeTab(tabID: tab.id))
        syncFromDaemon()
    }

    /// Whether ⇧⌘T has a tab to reopen (drives the menu item's enabled state).
    var canReopenClosedTab: Bool { lastClosedTab != nil }

    /// Reopen the most recently closed tab: spawn a fresh tab in its directory and
    /// restore a custom title if it had one. Consumes the stored entry so repeated
    /// presses don't keep cloning the same tab.
    func reopenLastClosedTab() {
        guard let workspace = snapshot.activeWorkspace, let closed = lastClosedTab else { return }
        let cwd = closed.cwd.isEmpty ? settings.defaultCWD : closed.cwd
        guard case let .tabID(tabID)? = requestDaemon(.newTab(workspaceID: workspace.id, cwd: cwd, shell: settings.defaultShell)) else {
            syncFromDaemon()
            return
        }
        lastClosedTab = nil
        // Only re-apply a deliberately customized title (skip the default "Shell").
        if !closed.title.isEmpty, closed.title != "Shell" {
            requestDaemon(.renameTab(tabID: tabID, name: closed.title))
        }
        syncFromDaemon()
        if let surfaceID = firstSurfaceID(forTab: tabID) {
            setActiveSurface(surfaceID)
            terminalHosts.host(for: surfaceID)?.focusTerminal()
        }
        // Same rationale as addTab: kick immediately, rely on the daemon's snapshotChanged
        // for any follow-up scan once the new PTY surface is live.
        SurfaceShellTracker.shared.bumpScan()
    }

    /// Toggle the find bar (⌘F) on the active pane's terminal surface.
    func toggleFindBar() {
        guard let surfaceID = activeSurfaceID, let host = terminalHosts.host(for: surfaceID) else { return }
        host.toggleFind()
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
        guard let session = snapshot.activeWorkspace?.activeSession else { return }
        closeSession(session)
    }

    /// Close a specific session by ID. The daemon resolves the ID directly — no
    /// select-first dance, so a failed/raced selection can never close a different
    /// session than the one the user confirmed.
    func closeSession(_ session: SessionGroup) {
        if let tab = session.activeTab { rememberTabForReopen(tab) }
        let surfaces = session.tabs.flatMap { $0.rootPane.allSurfaceIDs() }
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemon(.closeSession(sessionID: session.id))
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
        // Focus changed: snap the cwd tracker back to its responsive cadence (it relaxes
        // while nothing moves) — interaction predicts cwd changes.
        SurfaceShellTracker.shared.noteUserInteraction()
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
        var context = FormatContext(
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
        context.commandDurationSeconds = lastCommandDurations[surfaceID]
        return context
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
        // Write the per-tab option through (tmux: synchronize-panes IS a window
        // option), so `setw -t <tab> synchronize-panes` and the GUI toggle are one
        // state — the compositor honors the same option for the same tab.
        requestDaemon(.setOption(
            scope: "tab", target: tab.id.uuidString,
            key: "synchronize-panes", rawValue: nowOn ? "on" : "off"
        ))
        refreshSyncSiblings()
        DisplayMessage.show(nowOn ? "synchronize-panes: on" : "synchronize-panes: off")
    }

    /// Adopt per-tab `synchronize-panes` options written outside the GUI (`setw`,
    /// the compositor toggle) into the local mirror. Called from metadata sync.
    func adoptSynchronizeOptions() {
        guard case let .options(entries)? = requestDaemon(.showOptions(scope: "tab")) else { return }
        var changed = false
        for entry in entries where entry.key == "synchronize-panes" {
            guard let target = entry.target, let tabID = TabID(uuidString: target) else { continue }
            let on = entry.value == "on" || entry.value == "true" || entry.value == "1"
            if on != synchronizedTabIDs.contains(tabID) {
                if on { synchronizedTabIDs.insert(tabID) } else { synchronizedTabIDs.remove(tabID) }
                changed = true
            }
        }
        if changed { refreshSyncSiblings() }
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

    /// Select the active pane's last finished command output (OSC 133 marks; no-op without them).
    func selectLastCommandOutput() {
        guard let surfaceID = activeSurfaceID,
              let host = TerminalPaneRegistryAccess.host(for: surfaceID) else { return }
        host.selectLastCommandOutput()
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
            if let displayTheme = imported.themeName ?? imported.systemDarkThemeName {
                setTheme(displayTheme, seedColors: false)
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
        guard let workspace = snapshot.workspaces.first(where: { $0.id == id }) else { return }
        if let session = workspace.activeSession, let tab = session.activeTab {
            rememberTabForReopen(tab)
        }
        let surfaces = workspace.sessions.flatMap { session in
            session.tabs.flatMap { $0.rootPane.allSurfaceIDs() }
        }
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
            themeName: snapshot.themeName,
            endpoint: activeEndpoint
        )
        host.hostDelegate = self
        host.applyTheme(named: snapshot.themeName)
        host.applySettings(settings)
        applyTerminalIdentity(to: host)
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
                        agentKind: effectiveAgentKind(for: tab),
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
        // Focus the target pane so the keyboard is live immediately on arrival (mirrors
        // ensureActivePane/setActiveSurface) — selectTab alone leaves focus on the prior pane.
        terminalHosts.host(for: entry.surfaceID)?.focusTerminal()
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

    /// The tab-canonical surface used to key a notification's dedup entry: the first leaf of the
    /// tab owning `surfaceID`. `pushNewRemoteNotifications` (insert + prune) keys every entry by a
    /// waiting tab's `allSurfaceIDs().first`, so `handleNotification` must use the same anchor —
    /// keying by the raw ringing surface meant a bell in any non-first split pane produced a key the
    /// prune dropped on the very next snapshot, defeating the spam guard for that pane.
    private func canonicalNotificationSurface(for surfaceID: SurfaceID) -> SurfaceID {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                    return tab.rootPane.allSurfaceIDs().first ?? surfaceID
                }
            }
        }
        return surfaceID
    }

    func handleNotification(for surfaceID: SurfaceID, event: NotificationEvent, title: String, body: String) {
        let key = "\(canonicalNotificationSurface(for: surfaceID).uuidString)|\(body)"
        // Already pinged for this exact tab+message and it's still pending: just re-assert the
        // ring and return. A program spamming the bell (body is the constant "Bell") would
        // otherwise drive a full daemon notify + snapshot round-trip per `\a` on the main thread.
        // The key is cleared once the tab stops being `.waiting` (see `pushNewRemoteNotifications`),
        // so a genuinely new alert after dismissal still fires.
        guard !pushedNotificationKeys.contains(key) else {
            return
        }
        requestDaemon(.notify(
            surfaceID: surfaceID.uuidString,
            title: title,
            body: body
        ))
        pushedNotificationKeys.insert(key)
        if NSApp.isActive == false {
            deliverAgentAlert(event: event, title: title, body: body)
        }
        syncFromDaemon()
    }

    func clearNotification(for surfaceID: SurfaceID) {
        requestDaemon(.clearNotification(surfaceID: surfaceID.uuidString))
        syncFromDaemon()
    }

    func updateFontSize(delta: Float) {
        applyFontSize(settings.fontSize + delta)
    }

    /// ⌘0 — restore the default font size, completing the ⌘+/⌘-/⌘0 trio.
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

    /// Persist the secure-keyboard-entry setting and apply it immediately (takes/releases the
    /// process-global secure-input lock based on the new value + current app-active state).
    func setSecureKeyboardEntry(_ enabled: Bool) {
        guard settings.secureKeyboardEntry != enabled else { return }
        settings.secureKeyboardEntry = enabled
        try? settings.save()
        SecureKeyboardEntry.shared.settingChanged()
    }

    // MARK: Event-driven metadata + snapshot pushes
    // (replaced the 2 s loop that spawned `git rev-parse` per tab per tick and blind-synced
    // a full snapshot at 0.5 Hz forever)

    private func configureGitBranchMonitor() {
        gitBranchMonitor.onBranchChange = { [weak self] workspaceID, tabID, branch in
            // The daemon commit pushes back through the snapshot subscription, which is
            // what refreshes the visible label — no manual re-sync here.
            self?.logIfFailed(.updateTabGitBranch(workspaceID: workspaceID, tabID: tabID, branch: branch))
        }
    }

    /// The active workspace's tabs, shaped for the branch monitor. Matches the old poll's
    /// scope: background workspaces refresh when they become active.
    private func gitBranchRecords(from snapshot: SessionSnapshot) -> [GitBranchMonitor.TabRecord] {
        guard let workspace = snapshot.activeWorkspace else { return [] }
        return workspace.sessions.flatMap(\.tabs).map { tab in
            GitBranchMonitor.TabRecord(
                workspaceID: workspace.id,
                tabID: tab.id,
                cwd: tab.cwd,
                snapshotBranch: tab.gitBranch
            )
        }
    }

    /// Subscribe to the daemon's snapshot pushes if not already subscribed. Called after
    /// every successful sync, so the channel comes up as soon as the daemon answers; the
    /// follow-up async sync closes the fetch→subscribe race (a revision committed between
    /// the snapshot we just fetched and the subscription registering).
    private func startSnapshotSubscriptionIfNeeded() {
        guard snapshotSubscription == nil else { return }
        startSnapshotSubscription()
        guard snapshotSubscription != nil else {
            // The subscribe attempt failed (daemon briefly down): without this, recovery
            // would degrade to the 30 s safety poll — onEnd never fires for a channel
            // that never came up.
            scheduleSnapshotResubscribe()
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = self?.syncFromDaemon(metadataOnly: true) }
        }
    }

    private func startSnapshotSubscription() {
        snapshotSubscriptionGeneration += 1
        let generation = snapshotSubscriptionGeneration
        snapshotSubscription?.cancel()
        snapshotSubscription = try? daemon.subscribeSnapshot(
            label: "harness-app",
            onRevision: { [weak self] revision in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, generation == self.snapshotSubscriptionGeneration else { return }
                        self.handlePushedRevision(revision)
                    }
                }
            },
            onEnd: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, generation == self.snapshotSubscriptionGeneration else { return }
                        self.snapshotSubscription = nil
                        self.scheduleSnapshotResubscribe()
                    }
                }
            }
        )
        if snapshotSubscription != nil { snapshotResubscribeDelay = 1 }
    }

    private func handlePushedRevision(_ revision: Int) {
        // Echo guard: our own mutations sync synchronously, so the push for a revision we
        // already hold must not trigger a second fetch.
        guard revision != lastRevision else { return }
        // metadataOnly: a pushed revision must never rebuild every pane's renderer — the
        // daemon commits at ~1.5 s cadence while an agent streams. Structure changes still
        // remount (structureChanged is computed independently) and a CLI theme change still
        // applies (themeChanged forces the chrome path inside syncFromDaemon).
        syncFromDaemon(metadataOnly: true)
    }

    /// The daemon went away (restart, backlog eviction, socket death): retry with capped
    /// backoff until it answers. On success, sync immediately — revisions pushed during
    /// the gap were lost with the socket.
    private func scheduleSnapshotResubscribe() {
        let delay = snapshotResubscribeDelay
        snapshotResubscribeDelay = min(delay * 2, 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.snapshotSubscription == nil else { return }
                self.startSnapshotSubscription()
                if self.snapshotSubscription != nil {
                    self.syncFromDaemon(metadataOnly: true)
                } else {
                    self.scheduleSnapshotResubscribe()
                }
            }
        }
    }

    private func startSafetyPoll() {
        safetyPollTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncFromDaemon(metadataOnly: true) }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        safetyPollTimer = timer
    }

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        // Any number of external `git` operations may have happened while the watchers
        // were paused — resume re-resolves and re-reads everything.
        gitBranchMonitor.resume()
        startSafetyPoll()
    }

    @objc private func appDidResignActive() {
        gitBranchMonitor.pause()
        safetyPollTimer?.invalidate()
        safetyPollTimer = nil
    }

    private var lastDaemonErrorNotice: Date?

    // MARK: OSC 1337 user variables (coalesced daemon push)

    /// Pending `SetUserVar` pushes, coalesced per (surface, name): a flood of sequences
    /// becomes at most one synchronous daemon `setOption` per name per flush window,
    /// instead of one main-thread IPC round trip (plus a snapshot-subscriber broadcast)
    /// per escape sequence.
    private var pendingUserVariables: [SurfaceID: [String: String]] = [:]
    /// Names already pushed to the daemon per surface — the per-surface population cap
    /// (mirroring the engine's per-epoch cap) and the set a RIS must reset.
    private var pushedUserVariableNames: [SurfaceID: Set<String>] = [:]
    private var userVariableFlushScheduled = false
    private static let maxUserVariablesPerSurface = 64

    @discardableResult
    func requestDaemon(_ request: IPCRequest) -> IPCResponse? {
        do {
            return try daemon.request(request)
        } catch {
            // Never block the UI with a modal: a transient miss (e.g. the daemon
            // is still spawning at launch) must degrade gracefully. Log always,
            // and surface a non-blocking, throttled toast so the user isn't left
            // wondering — but the app keeps running and self-heals on the next sync.
            fputs("Harness daemon request failed: \(error)\n", harnessStderr)
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
            fputs("Harness daemon metadata update failed: \(error)\n", harnessStderr)
        }
    }
}

extension SessionCoordinator: TerminalHostDelegate {
    func terminalHostDidChangeTitle(_ title: String, surfaceID: SurfaceID) {
        logIfFailed(.updateTabTitle(surfaceID: surfaceID.uuidString, title: title))
        syncFromDaemon(metadataOnly: true)
    }

    /// OSC 9;4 progress — ephemeral GUI state (Ghostty parity), deliberately NOT mirrored
    /// to the daemon: keep-alives arrive ~1/s per working agent and must not churn
    /// layout.json commits. The tracker nudges a metadata-only tab refresh on transitions.
    func terminalHostDidUpdateProgress(_ report: TerminalProgressReport, surfaceID: SurfaceID) {
        SurfaceProgressTracker.shared.update(report, forSurface: surfaceID)
    }

    func terminalHostDidChangeWorkingDirectory(_ path: String, surfaceID: SurfaceID) {
        logIfFailed(.updateTabCwd(surfaceID: surfaceID.uuidString, path: path))
        syncFromDaemon(metadataOnly: true)
    }

    /// OSC 1337 `SetUserVar=` → a pane-scoped `@name` user option, so `#{@name}` format
    /// tokens (status line, pane borders, hooks) read it like any other user option. The
    /// engine already validated and bounded the name/value; `@`-options always pass the
    /// daemon's key validation. Pushes are coalesced (see `pendingUserVariables`) — the
    /// engine dedupes same-value rewrites, this bounds genuinely-changing floods.
    func terminalHostDidSetUserVariable(_ name: String, value: String, surfaceID: SurfaceID) {
        var names = pushedUserVariableNames[surfaceID, default: []]
        if !names.contains(name) {
            // Per-surface name cap, mirroring the engine's: defense in depth so a hostile
            // stream can't grow options.json even if the engine's own bound regresses.
            guard names.count < Self.maxUserVariablesPerSurface else { return }
            names.insert(name)
            pushedUserVariableNames[surfaceID] = names
        }
        pendingUserVariables[surfaceID, default: [:]][name] = value
        scheduleUserVariableFlush()
    }

    /// RIS dropped the engine's user variables — reset the daemon mirror so `#{@name}`
    /// stops serving pre-reset values. There is no unset IPC, so each pushed name is set
    /// to "" (renders as empty in formats) via the same coalesced path; the bookkeeping
    /// is forgotten so the name cap re-arms for the post-reset epoch.
    func terminalHostDidClearUserVariables(surfaceID: SurfaceID) {
        guard let names = pushedUserVariableNames.removeValue(forKey: surfaceID), !names.isEmpty else { return }
        for name in names { pendingUserVariables[surfaceID, default: [:]][name] = "" }
        scheduleUserVariableFlush()
    }

    /// One short debounce window shared by all surfaces: `SetUserVar` can arrive in bursts
    /// (a status updater in a shell loop) and each daemon round trip is synchronous on main.
    private func scheduleUserVariableFlush() {
        guard !userVariableFlushScheduled else { return }
        userVariableFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.userVariableFlushScheduled = false
            let pending = self.pendingUserVariables
            self.pendingUserVariables = [:]
            for (surfaceID, variables) in pending {
                for (name, value) in variables {
                    self.requestDaemon(.setOption(
                        scope: "pane", target: surfaceID.uuidString, key: "@\(name)", rawValue: value))
                }
            }
        }
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
        guard focused else { return }
        setActiveSurface(surfaceID)
        // Focus-in now fires on every click-into / ⌘-Tab-back (not only tab switches), so
        // gate the clear on the local `.waiting` state: `clearNotification` does a main-thread
        // `requestDaemon` + full `syncFromDaemon`, and there's nothing to clear on a pane with
        // no badge. The snapshot lookup is cheap and keeps the hot path off the daemon.
        guard tabIsWaiting(forSurface: surfaceID) else { return }
        clearNotification(for: surfaceID)
    }

    /// Whether the tab owning `surfaceID` currently shows a `.waiting` notification, read from
    /// the local snapshot (no daemon round-trip).
    private func tabIsWaiting(forSurface surfaceID: SurfaceID) -> Bool {
        snapshot.workspaces
            .flatMap { workspace in workspace.sessions.flatMap { $0.tabs } }
            .first { $0.rootPane.allSurfaceIDs().contains(surfaceID) }?
            .status == .waiting
    }

    func terminalHostDidRingBell(surfaceID: SurfaceID) {
        // In-app feedback for the ringing surface, honored on every BEL regardless of focus
        // (a focused bell was previously silent). The GUI `bellMode` setting decides, with the
        // tmux `visual-bell`/`bell-action` options bridging in via the shared resolver.
        let visualBell = HarnessOptions.shared.get("visual-bell", scope: .global)?.stringValue
        let bellAction = HarnessOptions.shared.get("bell-action", scope: .global)?.stringValue
        let effect = BellFeedback.resolve(mode: settings.bellMode, visualBell: visualBell, bellAction: bellAction)
        if effect.audible { NSSound.beep() }
        if effect.visual { terminalHosts.host(for: surfaceID)?.flashBell() }
        // tmux `bell-action off`/`none` silences the alert path too; otherwise keep the existing
        // tab bell-flag + (unfocused) OS-banner notification.
        if bellAction == "off" || bellAction == "none" { return }
        handleNotification(for: surfaceID, event: .bell, title: "Terminal", body: "Bell")
    }

    func terminalHostDidFinishCommand(duration: TimeInterval, exitCode: Int?, surfaceID: SurfaceID) {
        // Every finished command updates `#{command_duration}` — the notification below stays
        // gated on the event toggle + threshold.
        lastCommandDurations[surfaceID] = duration
        guard settings.isEventEnabled(.commandFinished),
              duration >= Double(max(0, settings.commandFinishedThresholdSeconds)) else { return }
        // Only notify when this pane isn't the one being actively watched.
        if NSApp.isActive, surfaceID == activeSurfaceID { return }
        let code = exitCode ?? 0
        let status = code == 0 ? "succeeded" : "failed (exit \(code))"
        deliverAgentAlert(event: .commandFinished, title: "Command \(status)", body: "Ran for \(Self.formatDuration(duration)).")
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60, secs = total % 60
        if minutes < 60 { return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s" }
        let hours = minutes / 60, mins = minutes % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }

    func terminalHostDidRequestDesktopNotification(title: String, body: String, surfaceID: SurfaceID) {
        handleNotification(for: surfaceID, event: .agentWaiting, title: title, body: body)
    }

    func terminalHostDidClose(surfaceID: SurfaceID) {
        terminalHosts.removeHost(for: surfaceID)
        SurfaceProgressTracker.shared.forget(surfaceID)
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
        let center = UNUserNotificationCenter.current()
        // The delegate is set once in `requestAuthorizationIfNeeded` (called at app launch
        // before any notification can fire) and in `requestOrOpenSettings` / `sendTest`.
        // Re-setting it here on every banner delivery was redundant and slightly wasteful
        // (UNUserNotificationCenter retains the delegate strongly per Apple docs, so it can
        // never be nil'd between those bootstrap calls and this point).
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                add(title: title, body: body, withSound: withSound)
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    if granted {
                        add(title: title, body: body, withSound: withSound)
                    } else if withSound {
                        DispatchQueue.main.async { NSSound(named: "Glass")?.play() }
                    }
                }
            case .denied:
                if withSound {
                    DispatchQueue.main.async { NSSound(named: "Glass")?.play() }
                }
            @unknown default:
                add(title: title, body: body, withSound: withSound)
            }
        }
    }

    private static func add(title: String, body: String, withSound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = withSound ? .default : nil
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                fputs("Harness notification delivery failed: \(error)\n", harnessStderr)
            }
        }
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
