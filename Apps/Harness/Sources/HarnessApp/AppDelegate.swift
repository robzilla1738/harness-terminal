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
        SurfaceShellTracker.shared.start()
        // Follow the macOS system appearance for auto light/dark theme switching. The startup
        // application happens post-daemon-sync below (so the theme change reaches a ready daemon);
        // this observer handles every later Light/Dark flip.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                SessionCoordinator.shared.applyAutoThemeForCurrentAppearance()
                self?.mainWindowController?.applyChrome()
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
            // Apply the auto light/dark theme now that the daemon is hydrated (so the theme change
            // lands), then refresh the window chrome to match.
            SessionCoordinator.shared.applyAutoThemeForCurrentAppearance()
            self.mainWindowController?.applyChrome()
            Self.reconcileSessionPersistenceWithModeOnce()
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

    /// One-shot: align the daemon's keep-on-quit default with the chosen experience the first
    /// time we launch with modes. A fresh Plain install becomes ephemeral; an upgraded install
    /// (already keep-on-quit + migrated to Full Terminal) is a no-op. Keyed so it never overrides a
    /// later explicit choice the user makes in Settings.
    private static func reconcileSessionPersistenceWithModeOnce() {
        let key = "HarnessModePersistenceReconciledV1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let keep = SessionCoordinator.shared.settings.experienceMode.persistsSessionsByDefault
        // Mark reconciled ONLY after the daemon accepts the default. A launch while the daemon is
        // still spawning would otherwise burn the one-shot flag without ever applying the mode's
        // keep-on-quit default — leaving a fresh Plain install wrongly persistent forever.
        guard SessionCoordinator.shared.requestDaemon(.setKeepSessionsOnQuit(keep)) != nil else { return }
        UserDefaults.standard.set(true, forKey: key)
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
            DefaultTerminalOpener.open(urls, asWindow: asWindow)
        } else {
            queuedExternalOpens.append(contentsOf: urls.map { QueuedExternalOpen(url: $0, asWindow: asWindow) })
        }
    }

    private func drainQueuedExternalOpenURLs() {
        guard externalOpenReady, !queuedExternalOpens.isEmpty else { return }
        let opens = queuedExternalOpens
        queuedExternalOpens.removeAll()
        for open in opens {
            DefaultTerminalOpener.open([open.url], asWindow: open.asWindow)
        }
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
