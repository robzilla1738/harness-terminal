import AppKit
import Darwin
import HarnessCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?
    private var menuBarController: MenuBarController?
    private var notchController: NotchPanelController?
    private var terminalServicesProvider: TerminalServicesProvider?
    /// Observes the macOS system appearance so auto light/dark theme switching can follow it.
    private var appearanceObservation: NSKeyValueObservation?
    private var externalOpenReady = false
    private var queuedExternalOpens: [QueuedExternalOpen] = []

    private struct QueuedExternalOpen {
        let url: URL
        let asWindow: Bool
        let kind: ExternalOpenKind
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        StartupMetrics.shared.mark(.launchStart)
        // Build the UI immediately so launch never blocks on the daemon. The
        // coordinator starts from a default snapshot and repopulates the moment
        // the daemon answers (below) — no frozen window, no modal timeout dialog.
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        StartupMetrics.shared.mark(.firstWindow)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainMenu = MainMenuBuilder.build()
        // Finder folder right-click "New Harness Tab/Window Here" (declared in Info.plist NSServices).
        // NSApp.servicesProvider does not retain the provider, so hold it for the app's lifetime.
        let servicesProvider = TerminalServicesProvider()
        terminalServicesProvider = servicesProvider
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        // Menu-bar status item: workspaces + active agents, read from the daemon
        // (shell-agnostic). Lives for the app's lifetime.
        menuBarController = MenuBarController()
        notchController = NotchPanelController.shared
        notchController?.start()
        PrefixKeymap.shared.install()
        QuickTerminalController.shared.start()
        SurfaceShellTracker.shared.start()
        // Secure keyboard entry: take the process-global keylogging lock while frontmost iff the
        // user enabled it. Observes app-active transitions and releases the lock on resign/terminate.
        SecureKeyboardEntry.shared.start()
        // Follow the macOS system appearance so the effective theme and chrome refresh together.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.mainWindowController?.effectiveAppearanceDidChange()
            }
        }
        // Request notification authorization once at launch instead of on every
        // notification post. macOS only shows the system prompt the first time
        // and silently denies after; doing it eagerly means notifications can
        // start arriving as soon as the first agent transitions to `waiting`.
        DesktopNotifier.requestAuthorizationIfNeeded()

        // Locate/spawn the daemon off the main thread, then sync from real state.
        DaemonLauncher.shared.ensureRunning { ok in
            if ok { StartupMetrics.shared.mark(.daemonConnected) }
            let synced = SessionCoordinator.shared.syncFromDaemon()
            if !ok || !synced {
                SessionCoordinator.shared.noteDaemonError(DaemonClientError.timeout)
            }
            // Refresh the window chrome after the daemon is hydrated so it matches the effective theme.
            self.mainWindowController?.effectiveAppearanceDidChange()
            Self.reconcileSessionPersistenceWithMode()
            OnboardingController.presentIfNeeded()
            self.externalOpenReady = true
            if synced {
                self.drainQueuedExternalOpenURLs()
            } else if !self.queuedExternalOpens.isEmpty {
                // Daemon wasn't hydrated yet: opening a queued URL/.command now would create its tab
                // against a not-ready daemon and be dropped. Retry the drain on a bounded backoff
                // until a sync succeeds, instead of losing the open.
                self.retryQueuedExternalOpenDrain(attempt: 0)
            }
        }
    }

    private static let modePersistenceLastAppliedKey = "HarnessModePersistenceLastAppliedMode"

    /// Record that `mode`'s keep-on-quit default has been applied to the daemon, so the next
    /// launch's reconcile treats the mode as settled. Called after the launch-time apply below and
    /// from Settings when a preset switch applies the default live — without the latter, that
    /// switch would look like a cross-launch mode change and re-clobber any keep-on-quit override
    /// the user made after switching.
    static func recordModePersistenceApplied(_ mode: ExperienceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modePersistenceLastAppliedKey)
    }

    /// Align the daemon's keep-on-quit default with the chosen experience whenever the mode
    /// *changes* across launches. Switching presets (Plain ⇄ Persistent/Full/Agent) re-applies that
    /// preset's default; a stable mode is left untouched so an explicit in-Settings keep-on-quit
    /// override — or a per-session / per-tab pin — is never clobbered on relaunch. (The old V1 flag
    /// was a permanent one-shot, so a later mode switch silently failed to re-sync persistence.)
    /// A fresh Plain install becomes ephemeral; an upgraded Full install keeps sessions.
    private static func reconcileSessionPersistenceWithMode() {
        let defaults = UserDefaults.standard
        let mode = SessionCoordinator.shared.settings.experienceMode
        // Upgrade seed: installs that ran the old one-shot (V1) reconcile already have a settled —
        // possibly user-overridden — keep-on-quit value in the daemon. Treat the current mode as
        // already applied instead of re-imposing its default, which would clobber an explicit
        // Settings override (e.g. a Plain user who pinned keep-on-quit on would lose sessions on
        // the next quit).
        if defaults.string(forKey: modePersistenceLastAppliedKey) == nil,
           defaults.bool(forKey: "HarnessModePersistenceReconciledV1") {
            recordModePersistenceApplied(mode)
            return
        }
        guard defaults.string(forKey: modePersistenceLastAppliedKey) != mode.rawValue else { return }
        let keep = mode.persistsSessionsByDefault
        // Record the applied mode ONLY after the daemon accepts the default. A launch while the
        // daemon is still spawning would otherwise burn the key without ever applying the mode's
        // keep-on-quit default — leaving a fresh Plain install wrongly persistent forever.
        guard SessionCoordinator.shared.requestDaemon(.setKeepSessionsOnQuit(keep)) != nil else { return }
        recordModePersistenceApplied(mode)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the last window quits the app; the daemon (launchd-managed)
        // keeps sessions alive in the background so reopening reattaches.
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The daemon is owned by launchd and intentionally outlives the GUI — never tear it
        // down on quit. Persistent sessions and scrollback stay alive so `harness-cli attach`
        // and a subsequent app launch see the same state.
        //
        // Ephemeral sessions (Plain mode, not pinned) are the exception: on a *clean* quit we
        // close them so Plain feels like a normal terminal. This is a clean-quit-only contract
        // — a crash or force-quit leaves everything running (the daemon can't tell a crash from
        // "keep my work"), and the next clean quit will reap them. Synchronous + longer-timeout +
        // single retry so a momentarily busy daemon still reaps before the process exits.
        SessionCoordinator.shared.closeEphemeralSessionsBeforeQuit()
        // Balance any held secure-input enable before the process exits so the OS lock is never
        // leaked (a stranded enable forces secure input on system-wide until reboot).
        SecureKeyboardEntry.shared.releaseForShutdown()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueExternalOpen(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueueExternalOpen(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    /// Entry point for the Finder "New Harness Tab/Window Here" services (`TerminalServicesProvider`).
    /// Reuses the external-open queue so a service fired at cold launch waits for the daemon.
    func handleServiceOpen(directories: [URL], asWindow: Bool) {
        enqueueExternalOpen(directories, asWindow: asWindow)
    }

    private func enqueueExternalOpen(_ urls: [URL], asWindow: Bool = false) {
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        if externalOpenReady {
            // Theme files import/apply (touching settings + a setTheme IPC); everything else opens
            // a terminal exactly as before. Both paths need a hydrated daemon, so when not ready
            // each URL is queued with its kind and handled on the drain.
            performExternalOpen(urls.map { QueuedExternalOpen(url: $0, asWindow: asWindow, kind: ExternalOpenKind(for: $0)) })
        } else {
            queuedExternalOpens.append(contentsOf: urls.map {
                QueuedExternalOpen(url: $0, asWindow: asWindow, kind: ExternalOpenKind(for: $0))
            })
        }
    }

    /// Route each opened URL by kind: `.harnesstheme` files go through the theme importer, all
    /// others through the terminal opener. Terminal opens batch (one `DefaultTerminalOpener.open`
    /// preserves the existing folder/asWindow semantics); theme opens are handled individually.
    private func performExternalOpen(_ opens: [QueuedExternalOpen]) {
        let terminalOpens = opens.filter { $0.kind == .terminal }
        for open in opens where open.kind == .theme {
            ThemeImportController.handle(open.url)
        }
        for open in terminalOpens {
            DefaultTerminalOpener.open([open.url], asWindow: open.asWindow)
        }
    }

    private func drainQueuedExternalOpenURLs() {
        guard externalOpenReady, !queuedExternalOpens.isEmpty else { return }
        let opens = queuedExternalOpens
        queuedExternalOpens.removeAll()
        performExternalOpen(opens)
    }

    /// Bounded retry to drain opens that were queued at launch when the daemon wasn't yet hydrated.
    /// Re-syncs each tick; once a sync succeeds the queued URLs open against a ready daemon. ~10s cap
    /// so a permanently-down daemon doesn't retry forever.
    private func retryQueuedExternalOpenDrain(attempt: Int) {
        guard !queuedExternalOpens.isEmpty, attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.queuedExternalOpens.isEmpty else { return }
            if SessionCoordinator.shared.syncFromDaemon() {
                self.drainQueuedExternalOpenURLs()
            } else {
                self.retryQueuedExternalOpenDrain(attempt: attempt + 1)
            }
        }
    }
}
