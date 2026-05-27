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
        FirstRunExperience.offerCLIInstallIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !SessionCoordinator.shared.keepSessionsOnQuit
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !SessionCoordinator.shared.keepSessionsOnQuit {
            DaemonLauncher.shared.stopIfNeeded()
        }
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
