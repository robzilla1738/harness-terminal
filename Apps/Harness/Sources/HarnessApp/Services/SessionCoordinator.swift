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
    var settings = HarnessSettings.load()
    /// Hot-reload watchers for `settings.json` / `keybindings.json` (reload on save).
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
    /// dotfile sync) applies live when the file changes. The `fresh != settings` guard
    /// makes the app's OWN saves a no-op: it already updated the in-memory `settings` before writing,
    /// so the reload loads identical values and does nothing. `FileWatcher` delivers on the main
    /// queue, so `assumeIsolated` is safe (and hop-free) for this @MainActor coordinator.
    private func startConfigWatchers() {
        let settingsWatcher = FileWatcher(url: HarnessPaths.settingsURL) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let fresh: HarnessSettings
                do { fresh = try HarnessSettings.reload() }
                catch {
                    DisplayMessage.show("Could not reload settings.json. Your working settings are unchanged. Fix the file and save again.")
                    fputs("Harness: settings reload failed — \(error)\n", harnessStderr)
                    return
                }
                guard fresh != self.settings else { return }
                self.settings = fresh
                self.applySettingsToHosts()
                // Palette shortcuts live in settings.json too (`harness-cli keymap` already reads them).
                PaletteShortcuts.shared.reload()
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
        refreshSnapshot()
    }

    @objc private func notificationPosted(_ note: Notification) {
        guard note.userInfo?["notification"] is AgentNotification else { return }
        NotificationCenter.default.post(name: NotificationBus.shared.tabStatusChanged, object: nil)
    }

    /// Hydrate from the daemon's snapshot. Returns whether the fetch succeeded so launch-time callers
    /// can gate work (e.g. draining queued external opens) on a real hydration rather than guessing.
    // MARK: - Remote daemons

    /// The daemon the key window shows: `DaemonSidebar.localID` or a remote host's name.
    /// Commands, new panes, and `snapshot` belong to it.
    private(set) var activeOwner = DaemonSidebar.localID
    /// Every other daemon a window is on, kept live in the background. This Mac is always
    /// attached: it is either active or here.
    private var links: [String: DaemonLink] = [:]
    /// Hosts with a reconnect chain running, so drops during it don't start another.
    private var reconnectingHosts: Set<String> = []
    private var disconnectedHosts: Set<String> = []

    /// Every attached daemon, the active one first.
    var connectedOwners: [String] { [activeOwner] + links.keys.sorted() }

    func connectionDescription(for owner: String) -> String {
        if reconnectingHosts.contains(owner) { return "Reconnecting…" }
        if disconnectedHosts.contains(owner) || !isConnected(owner) { return "Disconnected" }
        return "Connected"
    }

    func retryConnection(_ owner: String) {
        guard owner != DaemonSidebar.localID else { return }
        if isConnected(owner) { remoteTunnelDropped(owner) }
        else { connectToRemote(named: owner) }
    }

    func isConnected(_ owner: String) -> Bool { owner == activeOwner || links[owner] != nil }

    /// The latest snapshot of `owner`'s daemon (empty when it isn't attached).
    func snapshot(for owner: String) -> SessionSnapshot {
        owner == activeOwner ? snapshot : links[owner]?.snapshot ?? SessionSnapshot()
    }

    /// A tab on any attached daemon.
    func tab(_ id: TabID) -> Tab? {
        for owner in connectedOwners {
            if let tab = snapshot(for: owner).workspaces.lazy.flatMap(\.sessions).flatMap(\.tabs).first(where: { $0.id == id }) {
                return tab
            }
        }
        return nil
    }

    /// Where a pane's daemon is reached: the attached daemon whose snapshot has it.
    private func endpoint(forSurface surfaceID: SurfaceID) -> Endpoint {
        guard !Self.surfaces(in: snapshot).contains(surfaceID) else { return activeEndpoint }
        return links.values.first { Self.surfaces(in: $0.snapshot).contains(surfaceID) }?.endpoint ?? activeEndpoint
    }

    func endpoint(forOwner owner: String) -> Endpoint? {
        owner == activeOwner ? activeEndpoint : links[owner]?.endpoint
    }

    func performLibrary(_ operation: LibraryOperation, owner: String,
                        completion: @escaping @MainActor @Sendable (Result<IPCResponse, Error>) -> Void) {
        guard let endpoint = endpoint(forOwner: owner) else {
            completion(.failure(SetupError.invalid("Reconnect to \(owner) first.")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<(IPCResponse, SessionSnapshot), Error> {
                let client = DaemonClient(endpoint: endpoint)
                guard case let .daemonStats(stats) = try client.request(.daemonStats),
                      stats.capabilities?.contains(DaemonStats.sessionLibrary) == true else {
                    throw SetupError.invalid("Update the daemon on this host to use Saved Setups and Recently Closed.")
                }
                let response = try client.request(.library(operation), timeout: 10)
                if case let .error(message) = response { throw SetupError.invalid(message) }
                return (response, try DaemonSessionService(endpoint: endpoint).fetchSnapshot())
            }
            DispatchQueue.main.async {
                switch result {
                case let .success((response, fresh)):
                    if owner == self.activeOwner { self.applySnapshot(fresh, metadataOnly: false) }
                    else { self.links[owner]?.accept(fresh) }
                    completion(.success(response))
                case let .failure(error): completion(.failure(error))
                }
            }
        }
    }

    /// Two panes on one machine: a pane can move next to the other (panes never cross daemons).
    func sameMachine(_ a: SurfaceID, _ b: SurfaceID) -> Bool {
        endpoint(forSurface: a) == endpoint(forSurface: b)
    }

    private static func surfaces(in snapshot: SessionSnapshot) -> Set<SurfaceID> {
        Set(snapshot.workspaces.flatMap { $0.sessions.flatMap { $0.tabs.flatMap { $0.rootPane.allSurfaceIDs() } } })
    }

    /// Make `owner`'s daemon the active one: its window came to the front. With `session`,
    /// that session (and its workspace) is selected before the first sync, so the window never
    /// flashes another. Nothing here waits on the daemon: the selection shows at once and the
    /// daemon hears about it off the main thread. The daemon that was active stays attached in
    /// the background, panes and all.
    func activate(owner: String, selecting session: SessionID? = nil) {
        if owner != activeOwner {
            guard let link = links.removeValue(forKey: owner) else { return }
            link.stop()
            attachLink(DaemonLink(owner: activeOwner, endpoint: activeEndpoint, snapshot: snapshot))
            switchActiveDaemon(to: owner, endpoint: link.endpoint, known: link.snapshot, selecting: session)
        } else if let session, let selected = select(session) {
            applySnapshot(selected, metadataOnly: false)
            refreshSnapshot()
        }
    }

    /// `snapshot` with `session` and its workspace active; nil when they already are (or no
    /// workspace has it). The selection goes to the daemon off the main thread; fetches and
    /// commands after it wait for it. The revision stays: the daemon's own commit moves it.
    private func select(_ session: SessionID) -> SessionSnapshot? {
        guard let index = snapshot.workspaces.firstIndex(where: { $0.sessions.contains { $0.id == session } }) else { return nil }
        var selected = snapshot
        let workspaceID = selected.workspaces[index].id
        selected.workspaces[index].activeSessionID = session
        selected.activeWorkspaceID = workspaceID
        guard selected != snapshot else { return nil }
        // The session first: selecting the workspace first would show its other session for a moment.
        send(.selectSession(workspaceID: workspaceID, sessionID: session), .selectWorkspace(id: workspaceID))
        return selected
    }

    /// Send selections to the active daemon off the main thread, in order (see `SelectionQueue`).
    private func send(_ requests: IPCRequest...) {
        selectionsSent += 1
        let queue = selections(for: activeEndpoint)
        for request in requests { queue.async(request) }
    }

    private func attachLink(_ link: DaemonLink) {
        link.onChange = { [weak self] link in self?.linkChanged(link) }
        link.onDirective = { [weak self] directive in self?.handleDirective(directive) }
        links[link.owner] = link
        link.start()
    }

    /// A background daemon moved: its windows and every sidebar re-render.
    private func linkChanged(_ link: DaemonLink) {
        pruneHosts()
        pushAgentNotifications()
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: ["revision": snapshot.revision, "structureChanged": false, "chromeChanged": false, "metadataOnly": false]
        )
    }

    /// Attach to a saved remote daemon and bring it to the front in a window (with `session`,
    /// that session). The windows on other daemons stay as they are.
    func connectToRemote(named name: String, showing session: SessionID? = nil) {
        attachRemote(named: name) { [weak self] attached in
            if attached { self?.showDaemon(name, session: session) }
        }
    }

    /// Attach to a saved remote daemon in the background, then call back on the main actor
    /// with whether it's attached. Bringing up the SSH tunnel blocks, so it runs off-main;
    /// failures show and change nothing.
    private var pendingRemoteAttachments: [String: (id: UUID, callbacks: [@MainActor @Sendable (Bool) -> Void])] = [:]

    func attachRemote(named name: String, then done: @escaping @MainActor @Sendable (Bool) -> Void) {
        if isConnected(name) {
            done(true)
            return
        }
        if pendingRemoteAttachments[name] != nil {
            pendingRemoteAttachments[name]?.callbacks.append(done)
            return
        }
        let id = UUID()
        pendingRemoteAttachments[name] = (id, [done])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Carry Sendable values (an endpoint, a snapshot, a message) back to the main actor.
            var resolved: Endpoint?
            var failureMessage: String?
            do {
                resolved = try RemoteHostsService.shared.connect(named: name)
            } catch {
                failureMessage = "\(error)"
            }
            let endpoint = resolved
            let first = endpoint.flatMap { try? DaemonSessionService(endpoint: $0).fetchSnapshot() }
            let message = failureMessage ?? "\(name) didn't answer"
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.pendingRemoteAttachments[name]?.id == id else {
                        if self.pendingRemoteAttachments[name] == nil, !self.isConnected(name) {
                            RemoteHostsService.shared.disconnect(named: name)
                        }
                        return
                    }
                    let callbacks = self.pendingRemoteAttachments.removeValue(forKey: name)?.callbacks ?? []
                    guard let endpoint, let first else {
                        self.noteDaemonError(DaemonSessionError.daemonError(message))
                        callbacks.forEach { $0(false) }
                        return
                    }
                    if !self.isConnected(name) {
                        self.attachLink(DaemonLink(owner: name, endpoint: endpoint, snapshot: first))
                    }
                    self.disconnectedHosts.remove(name)
                    callbacks.forEach { $0(true) }
                }
            }
        }
    }

    /// Bring an attached daemon to the front: the window showing `session`, else a window
    /// already on that daemon (switched to `session`), else a new window.
    func showDaemon(_ owner: String, session: SessionID? = nil) {
        guard isConnected(owner) else { return }
        if let session, let window = WindowContexts.window(showing: session) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let snap = snapshot(for: owner)
        if let context = WindowContexts.all.first(where: { $0.owner == owner && $0.window != nil }), let window = context.window {
            activate(owner: owner, selecting: session ?? context.sessionID)
            window.makeKeyAndOrderFront(nil)
            // Becoming key selects the window's own session: `session` replaces it.
            if let session { activate(owner: owner, selecting: session) }
            return
        }
        guard let target = session ?? snap.activeWorkspace?.activeSessionID ?? snap.workspaces.first?.sessions.first?.id else { return }
        (NSApp.delegate as? AppDelegate)?.openWindow(showing: target, owner: owner)
    }

    /// A tunnel died (sleep, Wi-Fi change, remote reboot). Bring it back with backoff
    /// instead of leaving that daemon's windows on a dead socket.
    func remoteTunnelDropped(_ name: String) {
        // One reconnect chain per host: a retry's own short-lived ssh also reports a drop.
        guard isConnected(name), !reconnectingHosts.contains(name) else { return }
        reconnectingHosts.insert(name)
        disconnectedHosts.insert(name)
        NotificationCenter.default.post(name: NotificationBus.shared.snapshotChanged, object: self)
        DisplayMessage.show("Lost the connection to \(name). Reconnecting…")
        scheduleRemoteReconnect(name, attempt: 0)
    }

    private func scheduleRemoteReconnect(_ name: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + RemoteReconnect.delay(attempt: attempt)) { [weak self] in
            MainActor.assumeIsolated {
                // The person may have disconnected meanwhile.
                guard let self, self.isConnected(name) else {
                    self?.reconnectingHosts.remove(name)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let endpoint = try? RemoteHostsService.shared.connect(named: name)
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard self.isConnected(name) else {
                                self.reconnectingHosts.remove(name)
                                return
                            }
                            if let endpoint {
                                self.disconnectedHosts.remove(name)
                                self.reconnectingHosts.remove(name)
                                if self.activeOwner == name {
                                    self.switchActiveDaemon(to: name, endpoint: endpoint)
                                } else {
                                    self.links[name]?.start(endpoint: endpoint)
                                }
                                DisplayMessage.show("Reconnected to \(name).")
                            } else if attempt + 1 < RemoteReconnect.maxAttempts {
                                self.scheduleRemoteReconnect(name, attempt: attempt + 1)
                            } else {
                                self.reconnectingHosts.remove(name)
                                NotificationCenter.default.post(name: NotificationBus.shared.snapshotChanged, object: self)
                                DisplayMessage.show("Couldn't reach \(name). Use Remote ▸ \(name) ▸ Retry Connection to try again.")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Detach from a remote daemon: its windows close (the last one moves to this Mac), and
    /// its tunnel goes down. Its sessions keep running there.
    func disconnectRemote(named name: String) {
        guard name != DaemonSidebar.localID else { return }
        let callbacks = pendingRemoteAttachments.removeValue(forKey: name)?.callbacks ?? []
        callbacks.forEach { $0(false) }
        guard isConnected(name) else {
            RemoteHostsService.shared.disconnect(named: name)
            return
        }
        if activeOwner == name {
            // This Mac is attached whenever a remote is active.
            guard let local = links.removeValue(forKey: DaemonSidebar.localID) else { return }
            local.stop()
            switchActiveDaemon(to: DaemonSidebar.localID, endpoint: local.endpoint, known: local.snapshot)
        } else {
            links.removeValue(forKey: name)?.stop()
        }
        RemoteHostsService.shared.disconnect(named: name)
        reconnectingHosts.remove(name)
        pruneHosts()
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: ["revision": snapshot.revision, "structureChanged": true, "chromeChanged": false, "metadataOnly": false]
        )
    }

    /// Sessions on every attached daemon, grouped by machine, for the sidebar and switcher.
    func sidebarGroups() -> [DaemonSidebarGroup] {
        var rows: [DaemonSidebarSession] = []
        for owner in connectedOwners {
            guard let workspace = snapshot(for: owner).activeWorkspace else { continue }
            rows += workspace.sessions.map { session in
                DaemonSidebarSession(id: session.id.uuidString, name: SessionDisplayName.title(of: session, in: workspace), owner: owner)
            }
        }
        return DaemonSidebar.groups(
            localTitle: "This Mac",
            sessions: rows,
            remoteHosts: connectedOwners.filter { $0 != DaemonSidebar.localID }.sorted(),
            remoteDetail: RemoteAttach.explanation
        ).map { group in
            var group = group
            if !group.local { group.detail = connectionDescription(for: group.id) }
            return group
        }
    }

    /// A session row from another daemon: show it in a window (connecting first if needed).
    func focusSidebar(owner: String, sessionID: String) {
        let target = DaemonSidebar.splitDaemon(owner: owner)
        guard let id = UUID(uuidString: sessionID) else { return }
        if target == activeOwner, let workspace = snapshot.workspaces.first(where: { $0.sessions.contains { $0.id == id } }) {
            selectSession(workspaceID: workspace.id, sessionID: id)
        } else {
            connectToRemote(named: target, showing: id)
        }
    }

    func insertListedPath() {
        DirectoryBrowserController.present(over: NSApp.keyWindow ?? NSApp.mainWindow, mode: .insert)
    }

    func goToListedDirectory() {
        DirectoryBrowserController.present(over: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// Point commands, new panes, and the push channel at `owner`'s daemon and sync from it.
    /// Panes of the daemon that was active keep their hosts (its windows still show them).
    /// `known` is that daemon's last snapshot: it shows at once (with `session` selected) and
    /// stands in until the fetch answers off the main thread, so a daemon that's slow to answer
    /// never holds up the window or shows another machine's sessions as its own.
    private func switchActiveDaemon(to owner: String, endpoint: Endpoint, known: SessionSnapshot? = nil, selecting session: SessionID? = nil) {
        activeOwner = owner
        RemoteHostsService.shared.setActiveHost(owner == DaemonSidebar.localID ? nil : owner)
        activeEndpoint = endpoint
        daemon.switchEndpoint(endpoint)
        if let known {
            // Taken quietly first, so only the selection counts as a change.
            snapshot = known
            lastRevision = known.revision
            applySnapshot(session.flatMap(select) ?? known, metadataOnly: false)
        }
        // Re-point the push channel: the old subscription is pinned to the old daemon
        // (its onEnd is invalidated by the generation bump inside). A failed attempt has
        // no onEnd to retry from, so back off explicitly.
        startSnapshotSubscription()
        refreshSnapshot()
    }

    /// Drop hosts (and per-pane bookkeeping) for panes no attached daemon has any more.
    private func pruneHosts() {
        let live = connectedOwners.reduce(into: Set<SurfaceID>()) { $0.formUnion(Self.surfaces(in: snapshot(for: $1))) }
        terminalHosts.prune(keeping: live)
        surfaceRemoteHosts = surfaceRemoteHosts.filter { live.contains($0.key) }
        lastCommandDurations = lastCommandDurations.filter { live.contains($0.key) }
    }

    func syncFromDaemon(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        requestDaemonAsync(.getSnapshot, refresh: false) { [weak self] response in
            guard let self, case let .snapshot(snapshot)? = response else { completion(false); return }
            self.applySnapshot(snapshot, metadataOnly: false)
            completion(true)
        }
    }

    /// Bumped by every applied snapshot, so an off-main fetch that started earlier can tell a
    /// newer sync already landed and drop its (possibly older) answer.
    private var appliedSnapshots = 0

    private func applySnapshot(_ remote: SessionSnapshot, metadataOnly: Bool) {
        StartupMetrics.shared.mark(.firstSnapshot) // idempotent: records the first hydration only
        appliedSnapshots += 1
        // Nothing moved (the safety poll, a sync after an action that changed nothing): no
        // window needs to hear about it.
        if metadataOnly, remote == snapshot, lastRevision == remote.revision { return }
        let structureChanged = structureFingerprint(remote) != structureFingerprint(snapshot)
        // A CLI-driven theme change arrives by push (metadata-only), so it must force the
        // chrome path itself — recurring syncs otherwise never rebuild renderers.
        let themeChanged = remote.themeName != snapshot.themeName
        if let error = remote.persistenceError, error != snapshot.persistenceError {
            DisplayMessage.show("Sessions could not be saved: \(error)")
        }
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
            // Per-surface bookkeeping leaks one entry per pane ever created otherwise: these
            // only shrink on explicit callbacks (an OSC 7 nil-host reset / a command finish),
            // which a killed pane never emits. Panes on other attached daemons stay.
            pruneHosts()
        }
        pushAgentNotifications()
        // Hosts only need re-skinning when the theme moved (settings changes re-apply on their
        // own path, and new hosts are themed when they're made). Options a command may have
        // changed (synchronize-panes, the marked pane, profiles) still re-adopt on full syncs.
        if themeChanged { updateChromeAndHosts() }
        if !metadataOnly || themeChanged { adoptHostOptions() }
        updateDockBadge(from: remote)
        reflectRemoteActivePane()
        NotificationCenter.default.post(
            name: NotificationBus.shared.snapshotChanged,
            object: nil,
            userInfo: [
                "revision": remote.revision,
                "structureChanged": structureChanged,
                "chromeChanged": themeChanged,
                "metadataOnly": metadataOnly,
            ]
        )
    }

    /// Clean-quit reap of ephemeral (Plain-mode, unpinned) sessions. Best-effort but *reliable*: the
    /// daemon can be momentarily busy at quit and a single default-timeout request that drops would
    /// silently leave Plain tabs alive (breaking "quit closes my tabs"). Uses a longer timeout and one
    /// retry, and is bounded so it can never hang process exit. Synchronous — must finish before exit.
    /// Every attached daemon reaps its own: a remote window in front mustn't leave this Mac's
    /// Plain tabs running (or the other way round).
    func closeEphemeralSessionsBeforeQuit() {
        let clients = [DaemonClient(endpoint: activeEndpoint)] + links.values.map { DaemonClient(endpoint: $0.endpoint) }
        for client in clients {
            var confirmed = false
            for attempt in 0 ..< 2 where !confirmed {
                confirmed = (try? client.request(.closeEphemeralSessions, timeout: 4)) != nil
                if !confirmed, attempt == 0 { Thread.sleep(forTimeInterval: 0.1) } // brief gap before the single retry
            }
            if !confirmed { fputs("Harness: closeEphemeralSessions did not confirm before quit\n", harnessStderr) }
        }
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

    /// After a full snapshot sync: adopt any synchronize-panes changes that arrived with the
    /// snapshot, rebuild the sibling lists for input mirroring, and re-assert the marked-pane
    /// border and per-pane profiles.
    private func adoptHostOptions() {
        adoptSynchronizeOptions()
        refreshSyncSiblings()
        reassertMarkedPane()
        // Foreground-command changes ride snapshot syncs, so profile matches re-evaluate here
        // too (host changes have their own delegate path). Cheap no-op without profiles.
        applyProfileOverridesToAllHosts()
    }

    // MARK: - Per-host/per-command profiles

    /// Last OSC 7-reported hostname per surface (nil entries are removed — "no host known").
    private var surfaceRemoteHosts: [SurfaceID: String] = [:]

    func terminalHostDidChangeRemoteHost(_ host: String?, surfaceID: SurfaceID) {
        if let host {
            surfaceRemoteHosts[surfaceID] = host
        } else {
            surfaceRemoteHosts.removeValue(forKey: surfaceID)
        }
        applyProfileOverride(for: surfaceID)
    }

    /// Re-evaluate the profile match for one surface and push (or clear) its canvas theme
    /// override. First matching rule wins; no match reverts to the global theme.
    private func applyProfileOverride(for surfaceID: SurfaceID) {
        guard let host = terminalHostIfExists(for: surfaceID) else { return }
        let profiles = settings.profiles
        guard !profiles.isEmpty else {
            host.profileThemeOverride = nil
            return
        }
        let remoteHost = surfaceRemoteHosts[surfaceID]
        let command = owningTab(forSurface: surfaceID)?.currentCommand
        host.profileThemeOverride = profiles
            .first { $0.matches(host: remoteHost, command: command, surface: surfaceID.uuidString) }?
            .theme
    }

    private func applyProfileOverridesToAllHosts() {
        // With no profiles configured, still clear any leftovers (rules were just deleted).
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    for surfaceID in tab.rootPane.allSurfaceIDs() {
                        applyProfileOverride(for: surfaceID)
                    }
                }
            }
        }
    }

    /// The tab whose split tree carries `surfaceID`, for per-pane profile context.
    private func owningTab(forSurface surfaceID: SurfaceID) -> Tab? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                    return tab
                }
            }
        }
        return nil
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

    private var attentionAlerts: [String: PaneAttentionAlerts] = [:]

    private func pushAgentNotifications() {
        let items = attentionList()
        for owner in connectedOwners where !disconnectedHosts.contains(owner) {
            var tracker = attentionAlerts[owner] ?? PaneAttentionAlerts()
            let alerts = tracker.alerts(for: items.filter { $0.owner == owner }.map(\.entry))
            attentionAlerts[owner] = tracker
            for alert in alerts {
                if NSApp.isActive, owner == activeOwner, alert.entry.surfaceID == activeSurfaceID { continue }
                let name = alert.entry.activity.mark?.app ?? alert.entry.activity.agent?.kind.displayName ?? "Harness"
                deliverAgentAlert(event: alert.event, title: "\(name) · \(alert.entry.tabTitle)", body: alert.message, owner: owner, surfaceID: alert.entry.surfaceID)
            }
        }
        attentionAlerts = attentionAlerts.filter { connectedOwners.contains($0.key) }
        announceAttentionChanges(in: connectedOwners.flatMap { snapshot(for: $0).workspaces })
    }

    /// Each tab's mark at the last snapshot, so VoiceOver hears when one starts needing you.
    private var announcedActivity: [TabID: TabActivity] = [:]
    private var lastAnnouncement = Date.distantPast

    /// VoiceOver: say when a tab comes to need you, fails, or finishes ("drifting cedar ›
    /// claude: needs you"). One announcement covers several tabs changing at once, and they're
    /// spaced at least two seconds apart so a busy session can't talk over everything.
    private func announceAttentionChanges(in workspaces: [Workspace]) {
        var changed: [String] = []
        var current: [TabID: TabActivity] = [:]
        for workspace in workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    let activity = TabActivity.of(tab)
                    current[tab.id] = activity
                    guard activity != announcedActivity[tab.id], activity == .blocked || activity == .error || activity == .done,
                          announcedActivity[tab.id] != nil, let state = TabStatusView.label(activity)
                    else { continue }
                    let name = SurfaceIdentity.label(directory: tab.cwd, program: tab.currentCommand, agent: tab.agent?.kind.commandToken)
                    changed.append("\(SessionDisplayName.title(of: session, in: workspace)) › \(name): \(state)")
                }
            }
        }
        announcedActivity = current
        guard !changed.isEmpty, NSWorkspace.shared.isVoiceOverEnabled, Date().timeIntervalSince(lastAnnouncement) >= 2 else { return }
        lastAnnouncement = Date()
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: changed.prefix(3).joined(separator: ". "), .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// Single delivery point for agent alerts. First gates on the per-event "which events
    /// notify me" choice (`isEventEnabled`); then honors the two delivery toggles:
    /// `systemNotificationsEnabled` (push banner) and `notificationSoundEnabled` (chime).
    /// Banner-on carries the sound; banner-off-but-chime-on still plays an in-app chime,
    /// so an enabled event is audible even when banners are suppressed.
    private func deliverAgentAlert(event: NotificationEvent, title: String, body: String, owner: String? = nil, surfaceID: SurfaceID? = nil) {
        guard settings.isEventEnabled(event) else { return }
        let wantBanner = settings.systemNotificationsEnabled
        let wantChime = settings.notificationSoundEnabled
        guard wantBanner || wantChime else { return }
        if wantBanner {
            DesktopNotifier.show(title: title, body: body, withSound: wantChime, owner: owner, surfaceID: surfaceID?.uuidString)
        } else if wantChime {
            NSSound(named: "Glass")?.play()
        }
    }

    private func updateDockBadge(from snapshot: SessionSnapshot) {
        DockTileRenderer.shared.update(from: snapshot)
    }

    func saveImmediately() {
        refreshSnapshot()
    }

    /// Switch appearance and repaint. Light uses the configured light theme even when the
    /// Mac is dark. Stored opacity and blur stay put.
    func setAppearanceMode(_ mode: HarnessAppearanceMode) {
        guard settings.appearanceMode != mode else { return }
        settings.appearanceMode = mode
        settings.clearThemeColorOverrides()
        if mode == .light || mode == .macOSSystem {
            if settings.systemLightThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.systemLightThemeName = ThemeManager.defaultSystemLightThemeName
            }
            if settings.systemDarkThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                settings.systemDarkThemeName = ThemeManager.defaultSystemDarkThemeName
            }
        }
        saveSettings()
        applySettingsToHosts()
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
        QuickTerminalController.shared.applyTransparency()
        let allowClipboard = HarnessOptions.shared.get("set-clipboard")?.boolValue ?? true
        let allowClipboardRead = HarnessOptions.shared.get("allow-clipboard-read")?.boolValue ?? false
        for host in terminalHosts.allHosts() {
            host.applyTheme(named: snapshot.themeName)
            host.applySettings(settings)
            host.allowProgramClipboardAccess = allowClipboard
            host.allowProgramClipboardRead = allowClipboardRead
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
            saveSettings()
        }
        let unchanged = snapshot.themeName == name
        requestDaemonAsync(.setTheme(name: name))
        refreshSnapshot()
        // Re-picking the current theme resets its colors: the sync alone doesn't re-skin.
        if unchanged { applySettingsToHosts() }
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
        saveSettings()
        requestDaemonAsync(.setTheme(name: document.name))
        refreshSnapshot()
        // The document may carry new colors under the theme name already in use.
        applySettingsToHosts()
    }

    func addWorkspace(name: String) {
        requestDaemonAsync(.newWorkspace(name: name))
        refreshSnapshot()
    }

    func addSession(to workspaceID: WorkspaceID, cwd: String? = nil, name: String? = nil) {
        createSession(in: workspaceID, cwd: cwd, name: name)
        refreshSnapshot()
        // Kick the cwd tracker immediately after session creation so the shell's working
        // directory lights up as early as possible.  A second kick follows the daemon's next
        // snapshotChanged notification (which arrives once the PTY/surface is live), so there
        // is no fixed timing dependency — the notification-driven path handles the "shell not
        // yet spawned" window without a magic timeout.
        SurfaceShellTracker.shared.bumpScan()
    }

    /// Ask the daemon for a session without syncing, so a caller can open its window before
    /// the snapshot that makes it active arrives.
    func createSession(in workspaceID: WorkspaceID, cwd: String? = nil, name: String? = nil,
                       completion: @escaping @MainActor @Sendable (SessionID?) -> Void = { _ in }) {
        let cwd = cwd ?? activeTabCWD ?? settings.defaultCWD
        requestDaemonAsync(.newSession(workspaceID: workspaceID, cwd: cwd, name: name, shell: settings.defaultShell)) {
            guard case let .sessionID(id)? = $0 else { completion(nil); return }
            completion(id)
        }
    }

    func addTab(to workspaceID: WorkspaceID, cwd: String? = nil) {
        requestDaemonAsync(.newTab(workspaceID: workspaceID, cwd: cwd ?? activeTabCWD ?? settings.defaultCWD, shell: settings.defaultShell))
        refreshSnapshot()
        // Kick the cwd tracker immediately so the new tab's path lights up without waiting
        // for the next 500ms tick.  When the daemon posts snapshotChanged for the new PTY
        // surface, syncFromDaemon is called again and SurfaceShellTracker's next tick picks
        // up the final cwd — removing the need for an additional 300ms delayed kick.
        SurfaceShellTracker.shared.bumpScan()
    }

    func openDefaultTerminalLaunch(_ launch: DefaultTerminalLaunchRequest) {
        guard let workspaceID = snapshot.activeWorkspace?.id ?? snapshot.workspaces.first?.id else { return }
        let cwd = launch.cwd ?? settings.defaultCWD, shell = settings.defaultShell
        let owner = activeOwner
        performDaemonOperation(operation: { service in
            guard case let .tabID(tabID) = try service.request(.newTab(workspaceID: workspaceID, cwd: cwd, shell: shell)) else {
                throw DaemonSessionError.unexpectedResponse
            }
            if let title = launch.title, !title.isEmpty { try service.request(.renameTab(tabID: tabID, name: title)) }
            let snapshot = try service.fetchSnapshot()
            guard let surfaceID = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
                .first(where: { $0.id == tabID })?.rootPane.allSurfaceIDs().first else {
                throw DaemonSessionError.unexpectedResponse
            }
            if let command = launch.command, !command.isEmpty {
                try service.request(.sendData(surfaceID: surfaceID.uuidString, data: Data((command + "\r").utf8)))
            }
            return .surfaceID(surfaceID.uuidString)
        }) { [weak self] response in
            guard let self, self.activeOwner == owner,
                  case let .surfaceID(raw)? = response, let surfaceID = UUID(uuidString: raw) else { return }
            self.setActiveSurface(surfaceID)
        }
    }

    func splitActivePane(direction: SplitDirection) {
        guard let workspace = snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let paneID = activeSurfaceID.flatMap({ paneID(for: $0, in: tab.rootPane) })
                ?? tab.rootPane.allPaneIDs().last
        else { return }
        requestDaemonAsync(.newSplit(tabID: tab.id, paneID: paneID, direction: direction, shell: settings.defaultShell))
        refreshSnapshot()
    }

    /// Move a tab into `session` (at `index`, else the end), or with nil into a new session of
    /// its own. Returns where it went. Moving into a new session doesn't sync, so the caller can
    /// open its window before the snapshot that makes it active arrives.
    func moveTab(_ tabID: TabID, toSession session: SessionID?, index: Int? = nil,
                 completion: @escaping @MainActor @Sendable (SessionID?) -> Void = { _ in }) {
        requestDaemonAsync(.moveTab(tabID: tabID, toSessionID: session, index: index)) {
            guard case let .sessionID(id)? = $0 else { completion(nil); return }
            completion(id)
        }
    }

    /// A pane dragged onto another: an edge splits the target with the dragged pane on that
    /// side, the middle swaps them. The dragged pane may come from another tab.
    func dropPane(_ source: SurfaceID, onto target: SurfaceID, zone: PaneDropZone) {
        let tabs = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
        guard let sourcePane = tabs.lazy.compactMap({ self.paneID(for: source, in: $0.rootPane) }).first,
              let targetPane = tabs.lazy.compactMap({ self.paneID(for: target, in: $0.rootPane) }).first
        else { return }
        let request: IPCRequest = zone.direction.map {
            .joinPane(sourcePaneID: sourcePane, destPaneID: targetPane, direction: $0, placement: zone.placement)
        } ?? .swapPanes(srcPaneID: sourcePane, dstPaneID: targetPane)
        requestDaemonAsync(request)
        refreshSnapshot()
    }

    /// A pane dropped on a tab moves into it, beside that tab's focused pane; dropped on empty
    /// tab-bar space it gets a tab of its own.
    func dropPane(_ source: SurfaceID, ontoTab tabID: TabID?) {
        let tabs = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
        guard let sourcePane = tabs.lazy.compactMap({ self.paneID(for: source, in: $0.rootPane) }).first else { return }
        let request: IPCRequest
        if let tabID, let tab = tabs.first(where: { $0.id == tabID }) {
            guard let anchor = tab.activePaneID ?? tab.rootPane.allPaneIDs().first, anchor != sourcePane else { return }
            request = .joinPane(sourcePaneID: sourcePane, destPaneID: anchor, direction: .horizontal, placement: .after)
        } else {
            request = .breakPane(paneID: sourcePane)
        }
        requestDaemonAsync(request)
        refreshSnapshot()
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
        selectionsSent += 1
        requestDaemonAsync(.selectWorkspace(id: id))
        refreshSnapshot()
    }

    func selectSession(workspaceID: WorkspaceID, sessionID: SessionID) {
        selectionsSent += 1
        // A session already showing in another window: go to that window (becoming key
        // selects it there) rather than pulling its panes into this one.
        if let window = WindowContexts.window(showing: sessionID), window !== NSApp.keyWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if snapshot.activeWorkspaceID == workspaceID,
           snapshot.activeWorkspace?.activeSessionID == sessionID
        {
            return
        }
        requestDaemonAsync(.selectSession(workspaceID: workspaceID, sessionID: sessionID))
        refreshSnapshot()
    }

    func selectTab(workspaceID: WorkspaceID, tabID: TabID) {
        selectionsSent += 1
        if snapshot.activeWorkspaceID == workspaceID,
           snapshot.activeWorkspace?.activeTabID == tabID
        {
            return
        }
        requestDaemonAsync(.selectTab(workspaceID: workspaceID, tabID: tabID))
        refreshSnapshot()
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

    private func closeActiveTabOnly() {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        let surfaces = tab.rootPane.allSurfaceIDs()
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemonAsync(.closeTab(tabID: tab.id))
        refreshSnapshot()
    }

    var canReopenClosedTab: Bool { !snapshot.library.recentlyClosed.isEmpty }

    func reopenLastClosedTab() {
        guard let closed = snapshot.library.recentlyClosed.first else { return }
        let owner = activeOwner
        performLibrary(.restoreClosed(closed.id), owner: owner) { result in
            switch result {
            case let .success(.sessionID(id)):
                self.refreshSnapshot()
                self.showDaemon(owner, session: id)
            case let .failure(error): DisplayMessage.show(error.localizedDescription)
            default: break
            }
        }
    }

    func toggleFindBar() {
        guard let surfaceID = activeSurfaceID, let host = terminalHosts.host(for: surfaceID) else { return }
        host.toggleFind()
    }

    func findInActivePane(forward: Bool) {
        guard let surfaceID = activeSurfaceID, let host = terminalHosts.host(for: surfaceID) else { return }
        if forward { host.findNext() } else { host.findPrevious() }
    }

    /// ⌘W: the focused pane when the tab is split, else the tab (or, for the last tab, its
    /// session or window). Asks first only when something other than a shell is running.
    func closeFocusedPaneOrTab() {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        let leaves = tab.rootPane.allLeaves()
        guard leaves.count > 1 else {
            closeActiveTabWithConfirmation()
            return
        }
        let leaf = leaves.first { $0.surfaceID == activeSurfaceID } ?? leaves.first { $0.id == tab.activePaneID } ?? leaves[0]
        let identity = PaneIdentity.of(leaf: leaf, in: tab)
        guard identity.isBusy else {
            killPane(surfaceID: leaf.surfaceID)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close this pane?"
        alert.informativeText = "\(identity.agent?.displayName ?? identity.program ?? "A program") is still running in it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Pane")
        alert.addButton(withTitle: "Cancel")
        let surfaceID = leaf.surfaceID
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.killPane(surfaceID: surfaceID) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    /// Spread the active tab's splits evenly: each divider sits where its panes get equal room
    /// along its axis (three side-by-side panes get a third each).
    func equalizeActiveSplits() {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        func weight(_ node: PaneNode, along direction: SplitDirection) -> Double {
            guard case let .branch(d, _, first, second) = node, d == direction else { return 1 }
            return weight(first, along: direction) + weight(second, along: direction)
        }
        func firstLeaf(_ node: PaneNode) -> PaneID? {
            switch node {
            case let .leaf(leaf): return leaf.id
            case let .branch(_, _, first, _): return firstLeaf(first)
            }
        }
        var changed = false
        func visit(_ node: PaneNode) {
            guard case let .branch(direction, ratio, first, second) = node else { return }
            let a = weight(first, along: direction), b = weight(second, along: direction)
            let even = a / (a + b)
            if abs(even - ratio) > 0.001, let firstID = firstLeaf(first), let secondID = firstLeaf(second) {
                requestDaemonAsync(.resizePaneRatio(tabID: tab.id, firstPaneID: firstID, secondPaneID: secondID, ratio: even))
                changed = true
            }
            visit(first)
            visit(second)
        }
        visit(tab.rootPane)
        if changed { refreshSnapshot() }
    }

    func closeActiveTabWithConfirmation() {
        guard let disposition = activeTabCloseDisposition(),
              let copy = closeConfirmationCopy(for: disposition)
        else { return }
        // Nothing but shells at their prompts: close without asking.
        if let tab = snapshot.activeWorkspace?.activeTab,
           !tab.rootPane.allLeaves().contains(where: { PaneIdentity.of(leaf: $0, in: tab).isBusy }) {
            performClose(disposition, closingWindow: NSApp.keyWindow)
            return
        }
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
        let surfaces = session.tabs.flatMap { $0.rootPane.allSurfaceIDs() }
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemonAsync(.closeSession(sessionID: session.id))
        refreshSnapshot()
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
            requestDaemonAsync(.closeTab(tabID: tab.id))
        }
        selectTab(workspaceID: workspace.id, tabID: keepID)
        refreshSnapshot()
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
        requestDaemonAsync(.killPane(paneID: paneID))
        refreshSnapshot()
    }

    func zoomActivePane() {
        guard let workspace = snapshot.activeWorkspace,
              let tab = workspace.activeTab,
              let paneID = activeSurfaceID.flatMap({ paneID(for: $0, in: tab.rootPane) })
                ?? tab.rootPane.allPaneIDs().last
        else { return }
        requestDaemonAsync(.zoomPane(paneID: paneID))
        refreshSnapshot()
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
        // One read of options.json serves both.
        let options = OptionStore()
        refreshPaneStyles(options)
        let showBorder = surfaceID.map { paneCount(forSurface: $0) > 1 } ?? false
        for host in terminalHosts.allHosts() {
            host.showsActiveBorder = showBorder && host.surfaceID == surfaceID
        }
        // pane-border labels re-evaluate per host (active state just changed above).
        refreshPaneBorders(options)
        NotificationCenter.default.post(name: .harnessActiveSurfaceDidChange, object: self)
        // Push focus to the daemon (single source of truth) so other clients —
        // attach-window compositors, target-less CLI commands — agree on the active
        // pane. Suppressed while reflecting a remote change to avoid a feedback loop. Off the
        // main thread: focus moves with every window that comes forward, on any daemon.
        if !suppressActivePaneSync, let surfaceID, let loc = tabAndPane(forSurface: surfaceID) {
            send(.selectPane(tabID: loc.tabID, paneID: loc.paneID))
        }
    }

    /// Read the `window-style`/`pane-style` options (fresh from the daemon-authored
    /// `options.json`, so a CLI `set-option` lands without an app restart) and push the
    /// resolved set to every host. Each host dims itself when inactive via its own
    /// `showsActiveBorder`. Called on focus changes — the moment dimming matters.
    func refreshPaneStyles(_ opts: OptionStore = OptionStore()) {
        func value(_ key: String) -> String { opts.get(key, scope: .global)?.stringValue ?? "" }
        let styles = PaneStyleSet(
            window: value("window-style"),
            windowActive: value("window-active-style"),
            pane: value("pane-style"),
            paneActive: value("pane-active-style")
        )
        let separators = CopyModeWords.smallWordSeparators(stored: opts.get("word-separators", scope: .global)?.stringValue)
        for host in terminalHosts.allHosts() {
            host.applyPaneStyles(styles)
            host.copyModeWordSeparators = separators
        }
    }

    /// Evaluate `pane-border-format` per host and push the label (or hide it when
    /// `pane-border-status off`). Read fresh from the daemon-authored `options.json`.
    func refreshPaneBorders(_ opts: OptionStore = OptionStore()) {
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
        requestDaemonAsync(.setOption(
            scope: "tab", target: tab.id.uuidString,
            key: "synchronize-panes", rawValue: nowOn ? "on" : "off"
        ))
        refreshSyncSiblings()
        DisplayMessage.show(nowOn ? "synchronize-panes: on" : "synchronize-panes: off")
    }

    /// Adopt per-tab `synchronize-panes` options written outside the GUI (`setw`,
    /// the compositor toggle) into the local mirror. Called from full syncs, so it asks off the
    /// main thread: a window coming forward never waits on a (remote) daemon for it.
    private func adoptSynchronizeOptions() {
        let service = DaemonSessionService(endpoint: activeEndpoint)
        let owner = activeOwner
        DispatchQueue.global(qos: .userInitiated).async {
            guard case let .options(entries)? = try? service.request(.showOptions(scope: "tab")) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard owner == self.activeOwner else { return }
                    var changed = false
                    for entry in entries where entry.key == "synchronize-panes" {
                        guard let target = entry.target, let tabID = TabID(uuidString: target) else { continue }
                        let on = entry.value == "on" || entry.value == "true" || entry.value == "1"
                        if on != self.synchronizedTabIDs.contains(tabID) {
                            if on { self.synchronizedTabIDs.insert(tabID) } else { self.synchronizedTabIDs.remove(tabID) }
                            changed = true
                        }
                    }
                    if changed { self.refreshSyncSiblings() }
                }
            }
        }
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
        requestDaemonAsync(.joinPane(sourcePaneID: sourcePane, destPaneID: destPane, direction: direction))
        setMarkedPane(false)
        refreshSnapshot()
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
    /// It lands after a debounce, so it goes to the tab's own daemon: the window may have gone
    /// behind one on another machine by then.
    func setSplitRatio(tabID: TabID, firstPaneID: PaneID, secondPaneID: PaneID, ratio: Double) {
        let request = IPCRequest.resizePaneRatio(tabID: tabID, firstPaneID: firstPaneID, secondPaneID: secondPaneID, ratio: ratio)
        logIfFailed(request, surface: tab(tabID)?.rootPane.allSurfaceIDs().first)
        refreshSnapshot()
    }

    /// Commit a tab drag-reorder. Full sync so the tab bar rebuilds in the new order
    /// (the metadata path updates pills in place by ID and wouldn't reflect a reorder).
    func reorderSession(workspaceID: WorkspaceID, sessionID: SessionID, toIndex: Int) {
        requestDaemonAsync(.reorderSession(workspaceID: workspaceID, sessionID: sessionID, toIndex: toIndex))
        refreshSnapshot()
    }

    func renameWorkspace(id: WorkspaceID, name: String) {
        requestDaemonAsync(.renameWorkspace(workspaceID: id, name: name))
        refreshSnapshot()
    }

    func reorderTab(workspaceID: WorkspaceID, tabID: TabID, toIndex: Int) {
        requestDaemonAsync(.reorderTab(workspaceID: workspaceID, tabID: tabID, toIndex: toIndex))
        refreshSnapshot()
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

    /// A daemon-relayed request from the CLI (`harness-cli copy-mode`).
    func handleDirective(_ directive: ClientDirective) {
        switch directive {
        case let .copyMode(surfaceID, enabled):
            guard let id = UUID(uuidString: surfaceID),
                  let host = TerminalPaneRegistryAccess.host(for: id),
                  host.isInCopyMode != enabled
            else { return }
            if enabled {
                host.enterCopyMode(modeKeys: HarnessOptions.shared.get("mode-keys", scope: .global)?.stringValue ?? "vi")
            } else {
                host.exitCopyMode()
            }
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

    /// Rename the active tab in a sheet on its window. The name sticks: the program's own
    /// title no longer replaces it.
    func beginRenameActiveTab() {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: tab.title)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "Tab name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let tabID = tab.id
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !name.isEmpty, let self else { return }
            self.requestDaemonAsync(.renameTab(tabID: tabID, name: name))
            refreshSnapshot()
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    func reimportTerminalConfig() {
        SettingsImportController.present()
    }

    func applyImportedSettings(_ imported: HarnessSettings) throws {
        try imported.save()
        settings = imported
        PaletteShortcuts.shared.reload()
        applySettingsToHosts()
        NotificationCenter.default.post(name: NotificationBus.shared.snapshotChanged, object: self)
    }

    func closeActiveWorkspace() {
        guard let id = snapshot.activeWorkspaceID, snapshot.workspaces.count > 1 else { return }
        closeWorkspace(id: id)
    }

    func closeWorkspace(id: WorkspaceID) {
        guard snapshot.workspaces.count > 1 else { return }
        guard let workspace = snapshot.workspaces.first(where: { $0.id == id }) else { return }
        let surfaces = workspace.sessions.flatMap { session in
            session.tabs.flatMap { $0.rootPane.allSurfaceIDs() }
        }
        for surfaceID in surfaces {
            terminalHosts.removeHost(for: surfaceID)
        }
        requestDaemonAsync(.closeWorkspace(id: id))
        refreshSnapshot()
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
            endpoint: endpoint(forSurface: surfaceID),
            requiresSessionLayout: connectedOwners.contains { Self.surfaces(in: snapshot(for: $0)).contains(surfaceID) }
        )
        host.hostDelegate = self
        host.applyTheme(named: snapshot.themeName)
        host.applySettings(settings)
        applyTerminalIdentity(to: host)
        pushBorderColors(to: host)
        // Hover × (#168): same kill-pane path as `prefix x`. The affordance itself is armed
        // per mount (multi-pane tabs only) by ContentAreaViewController.
        host.onPaneCloseRequested = { [weak self] in self?.killPane(surfaceID: surfaceID) }
        terminalHosts.register(host)
        return host
    }

    /// Kill the pane hosting `surfaceID` — the hover-close affordance's target is the pane
    /// under the pointer, not necessarily the active one, and (multi-window) not necessarily
    /// in the active tab. Routes the same daemon command as `kill-pane`.
    func killPane(surfaceID: SurfaceID) {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    guard let paneID = paneID(for: surfaceID, in: tab.rootPane) else { continue }
                    requestDaemonAsync(.killPane(paneID: paneID))
                    refreshSnapshot()
                    return
                }
            }
        }
    }

    func jumpToLatestNotification() {
        guard let item = attentionList().first(where: { $0.connected && $0.entry.activity.rank.needsYou }) else { return }
        openAttention(item)
    }

    /// All tabs currently `.waiting` plus enough context to render a notification
    /// dropdown row (workspace name, tab title, agent kind, notification body).
    func attentionList() -> [HostedAttention] {
        let entries = connectedOwners.flatMap { owner in
            SessionEditor(snapshot: snapshot(for: owner)).listAttention().map {
                HostedAttention(owner: owner, entry: $0, connected: !disconnectedHosts.contains(owner))
            }
        }
        return AttentionRank.sorted(entries, rank: { $0.entry.activity.rank }, lastActivity: { $0.entry.activity.updatedAt })
    }

    func openAttention(_ item: HostedAttention) {
        guard isConnected(item.owner), !disconnectedHosts.contains(item.owner) else {
            DisplayMessage.show("Reconnect to \(item.owner) to open this pane.")
            return
        }
        let entry = item.entry
        guard Self.surfaces(in: snapshot(for: item.owner)).contains(entry.surfaceID) else {
            DisplayMessage.show("This pane has closed.")
            return
        }
        showDaemon(item.owner, session: entry.sessionID)
        activate(owner: item.owner, selecting: entry.sessionID)
        selectTab(workspaceID: entry.workspaceID, tabID: entry.tabID)
        setActiveSurface(entry.surfaceID)
        terminalHosts.host(for: entry.surfaceID)?.focusTerminal()
        markAttentionRead(item)
    }

    func openSearchResult(_ match: OutputSearchMatch, owner: String, query: String, caseSensitive: Bool) -> Bool {
        guard isConnected(owner), Self.surfaces(in: snapshot(for: owner)).contains(match.surfaceID) else { return false }
        showDaemon(owner, session: match.sessionID)
        activate(owner: owner, selecting: match.sessionID)
        selectTab(workspaceID: match.workspaceID, tabID: match.tabID)
        setActiveSurface(match.surfaceID)
        guard let host = terminalHosts.host(for: match.surfaceID) else { return false }
        return host.revealSearchResult(match, query: query, caseSensitive: caseSensitive)
    }

    func markAttentionRead(_ item: HostedAttention) {
        updateAttention(.acknowledgeAttention(surfaceID: item.entry.surfaceID.uuidString), item: item)
    }

    func snoozeAttention(_ item: HostedAttention, minutes: Int) {
        updateAttention(.snoozeAttention(surfaceID: item.entry.surfaceID.uuidString, minutes: minutes), item: item)
    }

    private func updateAttention(_ request: IPCRequest, item: HostedAttention) {
        guard item.connected, let endpoint = endpoint(forOwner: item.owner) else { DisplayMessage.show("Reconnect to this host first."); return }
        DispatchQueue.global(qos: .utility).async {
            do {
                let response = try DaemonClient(endpoint: endpoint).request(request)
                if case let .error(message) = response { throw SetupError.invalid(message) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { DisplayMessage.show(message) }
            }
        }
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

    /// Store the report on its source pane; the unified activity stream delivers alerts.
    func handleNotification(for surfaceID: SurfaceID, event: NotificationEvent, title: String, body: String) {
        guard !attentionList().contains(where: { $0.entry.surfaceID == surfaceID && $0.entry.activity.notification == body }) else { return }
        requestDaemonBatch([.notify(surfaceID: surfaceID.uuidString, title: title, body: body)], endpoint: endpoint(forSurface: surfaceID))
        refreshSnapshot()
    }

    func clearNotification(for surfaceID: SurfaceID) {
        requestDaemonBatch([.clearNotification(surfaceID: surfaceID.uuidString)], endpoint: endpoint(forSurface: surfaceID))
        refreshSnapshot()
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
        saveSettings()
        for host in terminalHosts.allHosts() {
            host.applySettings(settings)
        }
    }

    /// Persist the secure-keyboard-entry setting and apply it immediately (takes/releases the
    /// process-global secure-input lock based on the new value + current app-active state).
    func saveSettings() {
        do { try settings.save() }
        catch { DisplayMessage.show("Settings could not be saved: \(error.localizedDescription)") }
    }

    func setSecureKeyboardEntry(_ enabled: Bool) {
        guard settings.secureKeyboardEntry != enabled else { return }
        settings.secureKeyboardEntry = enabled
        saveSettings()
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
        // A remote cwd belongs to the remote filesystem. A local lookup could erase its
        // real branch or substitute a different repository at the same path on this Mac.
        guard activeOwner == DaemonSidebar.localID else { return [] }
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
    /// follow-up background fetch closes the fetch→subscribe race (a revision committed
    /// between the snapshot we just fetched and the subscription registering).
    private var snapshotSubscriptionPending = false

    private func startSnapshotSubscriptionIfNeeded() {
        guard snapshotSubscription == nil, !snapshotSubscriptionPending else { return }
        startSnapshotSubscription()
    }

    private func startSnapshotSubscription() {
        snapshotSubscriptionGeneration += 1
        let generation = snapshotSubscriptionGeneration
        snapshotSubscription?.cancel()
        snapshotSubscription = nil
        snapshotSubscriptionPending = true
        let service = DaemonSessionService(endpoint: activeEndpoint)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let subscription = try? service.subscribeSnapshot(
                label: "harness-app",
                onRevision: { [weak self] revision in
                    DispatchQueue.main.async {
                        guard let self, generation == self.snapshotSubscriptionGeneration else { return }
                        self.handlePushedRevision(revision)
                    }
                },
                onDirective: { [weak self] directive in
                    DispatchQueue.main.async {
                        guard let self, generation == self.snapshotSubscriptionGeneration else { return }
                        self.handleDirective(directive)
                    }
                },
                onEnd: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, generation == self.snapshotSubscriptionGeneration else { return }
                        // Invalidate an attachment completion still on its way to main.
                        self.snapshotSubscriptionGeneration += 1
                        self.snapshotSubscriptionPending = false
                        self.snapshotSubscription = nil
                        self.scheduleSnapshotResubscribe()
                    }
                }
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.snapshotSubscriptionGeneration else {
                    subscription?.cancel()
                    return
                }
                self.snapshotSubscriptionPending = false
                self.snapshotSubscription = subscription
                if subscription != nil {
                    self.snapshotResubscribeDelay = 1
                    self.refreshSnapshot() // Close the fetch-to-subscribe revision gap.
                } else {
                    self.scheduleSnapshotResubscribe()
                }
            }
        }
    }

    private func handlePushedRevision(_ revision: Int) {
        // Echo guard: our own mutations sync synchronously, so the push for a revision we
        // already hold must not trigger a second fetch.
        guard revision != lastRevision else { return }
        refreshSnapshot()
    }

    /// Selections waiting to go out, one queue per daemon: fetches and commands wait only for
    /// their own daemon's, so a slow (or silently dead) remote never holds up this Mac.
    private var selectionQueues: [Endpoint: SelectionQueue] = [:]
    /// Bumped by every selection sent, so a background fetch that started earlier can tell its
    /// answer may predate it (an old active pane would pull focus back).
    private var selectionsSent = 0

    private func selections(for endpoint: Endpoint) -> SelectionQueue {
        if let queue = selectionQueues[endpoint] { return queue }
        let service = DaemonSessionService(endpoint: endpoint)
        let queue = SelectionQueue { _ = try? service.request($0) }
        selectionQueues[endpoint] = queue
        return queue
    }

    /// A background fetch is in flight / another was asked for while it was.
    private var fetchInFlight = false
    private var refetch = false

    /// Fetch the active daemon's snapshot off the main thread (a remote daemon answers over SSH)
    /// and apply it. metadataOnly: a pushed revision never rebuilds every pane's renderer — the
    /// daemon commits often while an agent streams. Structure changes still remount
    /// (structureChanged is computed independently) and a CLI theme change still applies
    /// (themeChanged forces the chrome path).
    func refreshSnapshot() {
        guard pendingDaemonOperations[activeEndpoint, default: 0] == 0 else { refetch = true; return }
        guard !fetchInFlight else {
            refetch = true
            return
        }
        fetchInFlight = true
        refetch = false
        let service = DaemonSessionService(endpoint: activeEndpoint)
        let owner = activeOwner
        let applied = appliedSnapshots
        let sent = selectionsSent
        let queue = selections(for: activeEndpoint)
        DispatchQueue.global(qos: .userInitiated).async {
            queue.sync {} // after the selections already sent, without holding up later ones
            let fresh = try? service.fetchSnapshot()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.fetchInFlight = false
                    // Another daemon became active, or a sync landed meanwhile (it is at least as
                    // new): this answer is stale. So is one that started before a selection went
                    // out (a pane click applies no snapshot): ask again, or the old active pane
                    // takes focus back.
                    if sent != self.selectionsSent {
                        self.refetch = true
                    } else if let fresh, owner == self.activeOwner, applied == self.appliedSnapshots {
                        self.applySnapshot(fresh, metadataOnly: true)
                    }
                    if self.refetch { self.refreshSnapshot() }
                }
            }
        }
    }

    /// The daemon went away (restart, backlog eviction, socket death): retry with capped
    /// backoff until it answers. On success, fetch at once — revisions pushed during the
    /// gap were lost with the socket.
    private func scheduleSnapshotResubscribe() {
        let delay = snapshotResubscribeDelay
        let generation = snapshotSubscriptionGeneration
        snapshotResubscribeDelay = min(delay * 2, 8)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.snapshotSubscriptionGeneration,
                  self.snapshotSubscription == nil, !self.snapshotSubscriptionPending else { return }
            self.startSnapshotSubscription()
        }
    }

    private func startSafetyPoll() {
        safetyPollTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
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

    func afterDaemonOperations(_ completion: @escaping @MainActor @Sendable () -> Void) {
        selections(for: activeEndpoint).perform { DispatchQueue.main.async { completion() } }
    }

    /// GUI operations are ordered per captured endpoint, independently of the input streams.
    /// A failed mutation is never retried; only a subsequent snapshot may reconcile its outcome.
    func requestDaemonAsync(_ request: IPCRequest, refresh: Bool = true, deliverStaleResult: Bool = false,
                            completion: @escaping @MainActor @Sendable (IPCResponse?) -> Void = { _ in }) {
        requestDaemonBatch([request], refresh: refresh, deliverStaleResult: deliverStaleResult, completion: completion)
    }

    func requestDaemonBatch(_ requests: [IPCRequest], refresh: Bool = true,
                            endpoint: Endpoint? = nil, deliverStaleResult: Bool = false,
                            completion: @escaping @MainActor @Sendable (IPCResponse?) -> Void = { _ in }) {
        performDaemonOperation(endpoint: endpoint, refresh: refresh, deliverStaleResult: deliverStaleResult, operation: { service in
            var response = IPCResponse.ok
            for request in requests { response = try service.request(request) }
            return response
        }, completion: completion)
    }

    private var pendingDaemonOperations: [Endpoint: Int] = [:]
    private(set) var daemonFailureRevision = 0

    func performDaemonOperation(endpoint: Endpoint? = nil, refresh: Bool = true, deliverStaleResult: Bool = false,
                                operation: @escaping @Sendable (DaemonSessionService) throws -> IPCResponse,
                                completion: @escaping @MainActor @Sendable (IPCResponse?) -> Void = { _ in }) {
        let endpoint = endpoint ?? activeEndpoint
        let owner = activeOwner, sent = selectionsSent
        let service = DaemonSessionService(endpoint: endpoint)
        pendingDaemonOperations[endpoint, default: 0] += 1
        selections(for: endpoint).perform { [weak self] in
            let result = Result { try operation(service) }
            let fresh = refresh ? try? service.fetchSnapshot() : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingDaemonOperations[endpoint, default: 1] -= 1
                let current = owner == self.activeOwner && endpoint == self.activeEndpoint && sent == self.selectionsSent
                switch result {
                case let .success(response): completion(current || deliverStaleResult ? response : nil)
                case let .failure(error):
                    self.daemonFailureRevision += 1
                    fputs("Harness daemon operation failed: \(error)\n", harnessStderr)
                    if current { DisplayMessage.show("\(error). Check the current state before trying again.") }
                    completion(nil)
                }
                if current, let fresh, fresh.revision >= self.snapshot.revision {
                    self.applySnapshot(fresh, metadataOnly: false)
                    self.refetch = false
                }
                if endpoint == self.activeEndpoint, self.refetch,
                   self.pendingDaemonOperations[endpoint, default: 0] == 0 { self.refreshSnapshot() }
            }
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
    /// What a pane reports goes to that pane's own daemon: a window behind may be on another
    /// machine. That daemon's next push refreshes whichever snapshot holds the pane.
    /// A request about one pane, sent to that pane's own daemon (errors show like any request).
    private func logIfFailed(_ request: IPCRequest, surface surfaceID: SurfaceID? = nil) {
        let endpoint = surfaceID.map(endpoint(forSurface:)) ?? activeEndpoint
        let service = DaemonSessionService(endpoint: endpoint)
        selections(for: endpoint).perform {
            do { try service.request(request) }
            catch { fputs("Harness daemon metadata update failed: \(error)\n", harnessStderr) }
        }
    }

}

extension SessionCoordinator: TerminalHostDelegate {
    func terminalHostDidChangeTitle(_ title: String, surfaceID: SurfaceID) {
        logIfFailed(.updateTabTitle(surfaceID: surfaceID.uuidString, title: title), surface: surfaceID)
        refreshSnapshot()
    }

    /// OSC 9;4 progress — ephemeral GUI state, deliberately NOT mirrored
    /// to the daemon: keep-alives arrive ~1/s per working agent and must not churn
    /// layout.json commits. The tracker nudges a metadata-only tab refresh on transitions.
    func terminalHostDidUpdateProgress(_ report: TerminalProgressReport, surfaceID: SurfaceID) {
        SurfaceProgressTracker.shared.update(report, forSurface: surfaceID)
    }

    func terminalHostDidChangeWorkingDirectory(_ path: String, surfaceID: SurfaceID) {
        logIfFailed(.updateTabCwd(surfaceID: surfaceID.uuidString, path: path), surface: surfaceID)
        refreshSnapshot()
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
                    self.logIfFailed(.setOption(
                        scope: "pane", target: surfaceID.uuidString, key: "@\(name)", rawValue: value), surface: surfaceID)
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
        logIfFailed(.updateTabCwd(surfaceID: surfaceID.uuidString, path: cwd), surface: surfaceID)
        refreshSnapshot()
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

    /// A `notify`-action output trigger matched (the surface already applied the per-rule
    /// cooldown). Routes through the same notification path as a program's OSC 9 — the rule
    /// itself is the opt-in, so there is no separate per-event toggle to trip over.
    func terminalHostDidMatchTrigger(_ rule: TriggerRule, lineText: String, surfaceID: SurfaceID) {
        handleNotification(
            for: surfaceID, event: .agentWaiting,
            title: "Trigger: \(rule.pattern)", body: lineText
        )
    }

    func terminalHostScriptActionFinished(_ result: ScriptActionResult, surfaceID: SurfaceID) {
        Self.applyScriptResult(result)
    }

    func terminalHostShowMessage(_ message: String, surfaceID: SurfaceID) {
        DisplayMessage.show(message)
    }

    func terminalHostSizeOwnershipChanged(_ ownership: SizeOwnership, surfaceID: SurfaceID) {
        NotificationCenter.default.post(name: .harnessSizeOwnershipDidChange, object: nil)
    }

    /// Copy a command that watches `surfaceID` read-only from any terminal: no typing, no
    /// resizing. A pane on a saved remote host gets `--host`.
    func copyWatchCommand(for surfaceID: SurfaceID) {
        var words = ["harness-cli"]
        if let host = RemoteHostsService.shared.activeHostName { words += ["--host", ShellQuoting.quote(host)] }
        words += ["attach", "--read-only", "--surface", surfaceID.uuidString]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(words.joined(separator: " "), forType: .string)
        DisplayMessage.show("Copied a read-only attach command")
    }

    /// Make this window's size the active pane's size, when another client owns it.
    func takeActivePaneSize() {
        guard let surfaceID = activeSurfaceID else { return }
        terminalHostIfExists(for: surfaceID)?.takeSize()
    }

    /// Show a Lua action's failure and run the commands it queued with `harness.queue`,
    /// through the same executor as the `:` prompt and key bindings.
    static func applyScriptResult(_ result: ScriptActionResult) {
        if let failure = result.failure { DisplayMessage.show(failure) }
        for command in result.queued {
            do {
                try MainExecutor.shared.executeSource(command)
            } catch {
                DisplayMessage.show("queued command failed: \(command): \(error)")
                return
            }
        }
    }

    func terminalHostDidClose(surfaceID: SurfaceID) {
        terminalHosts.removeHost(for: surfaceID)
        SurfaceProgressTracker.shared.forget(surfaceID)
    }
}

enum DesktopNotifier {
    /// Register foreground delivery without asking for permission before the user chooses setup.
    static func configurePresentation() {
        let center = UNUserNotificationCenter.current()
        // Without a delegate that opts in, macOS suppresses banners while Harness is
        // the *frontmost* app — so an agent notification fired while you're looking at
        // another tab would silently no-op. The presenter forces banner + sound + list
        // even in the foreground, so agent alerts always land.
        center.delegate = ForegroundPresenter.shared
    }

    static func show(title: String, body: String, withSound: Bool = true, owner: String? = nil, surfaceID: String? = nil) {
        let center = UNUserNotificationCenter.current()
        // The delegate is set once in `configurePresentation` (called at app launch
        // before any notification can fire) and in `requestOrOpenSettings` / `sendTest`.
        // Re-setting it here on every banner delivery was redundant and slightly wasteful
        // (UNUserNotificationCenter retains the delegate strongly per Apple docs, so it can
        // never be nil'd between those bootstrap calls and this point).
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                add(title: title, body: body, withSound: withSound, owner: owner, surfaceID: surfaceID)
            case .notDetermined, .denied:
                if withSound {
                    DispatchQueue.main.async { NSSound(named: "Glass")?.play() }
                }
            @unknown default:
                add(title: title, body: body, withSound: withSound, owner: owner, surfaceID: surfaceID)
            }
        }
    }

    private static func add(title: String, body: String, withSound: Bool, owner: String?, surfaceID: String?) {
        let content = UNMutableNotificationContent()
        if let owner, let surfaceID { content.userInfo = ["owner": owner, "surfaceID": surfaceID] }
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
        // UNUserNotificationCenter throws outside an app bundle (a unit test host, `swift run`).
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
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
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let owner = info["owner"] as? String
        let surface = (info["surfaceID"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            guard let owner, let surface else { return }
            let coordinator = SessionCoordinator.shared
            if let item = coordinator.attentionList().first(where: { $0.owner == owner && $0.entry.surfaceID == surface }) {
                NSApp.activate(ignoringOtherApps: true)
                coordinator.openAttention(item)
            } else { DisplayMessage.show("This pane has closed or its host is disconnected.") }
        }
        completionHandler()
    }

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

extension Notification.Name {
    /// The focused pane changed (pane headers re-dim on this).
    static let harnessActiveSurfaceDidChange = Notification.Name("HarnessActiveSurfaceDidChange")
    /// Some pane's size owner changed (its header shows or hides "Viewing at …").
    static let harnessSizeOwnershipDidChange = Notification.Name("HarnessSizeOwnershipDidChange")
}
