import AppKit
import Darwin
import GhosttyTerminal
import HarnessCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureTerminalDiagnostics()
        DaemonLauncher.shared.ensureRunning()
        SessionCoordinator.shared.syncFromDaemon()
        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainMenu = MainMenuBuilder.build()
        PrefixKeymap.shared.install()
        SurfaceShellTracker.shared.start()
        // Request notification authorization once at launch instead of on every
        // notification post. macOS only shows the system prompt the first time
        // and silently denies after; doing it eagerly means notifications can
        // start arriving as soon as the first agent transitions to `waiting`.
        DesktopNotifier.requestAuthorizationIfNeeded()
        FirstRunExperience.offerCLIInstallIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the last window quits the app; the daemon (launchd-managed)
        // keeps sessions alive in the background so reopening reattaches.
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The daemon is owned by launchd and intentionally outlives the GUI —
        // never tear it down on quit. Sessions and scrollback stay alive so
        // `harness-cli attach` and a subsequent app launch see the same state.
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func configureTerminalDiagnostics() {
        let environment = ProcessInfo.processInfo.environment
        if environment["HARNESS_GHOSTTY_DEBUG"] == "1" {
            TerminalDebugLog.enable(.standard)
        } else {
            TerminalDebugLog.disable()
            unsetenv("GHOSTTY_LOG")
        }
    }
}
