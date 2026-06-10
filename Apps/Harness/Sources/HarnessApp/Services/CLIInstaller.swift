import AppKit
import Foundation
import HarnessCore

@MainActor
enum CLIInstaller {
    static var binDirectory: URL { BinaryRefresher.binDirectory }

    static var installedCLIPath: URL { BinaryRefresher.installedCLIPath }

    static var installedDaemonPath: URL { BinaryRefresher.installedDaemonPath }

    @discardableResult
    static func install() -> Bool {
        // Gate on the source binary before spinning up the background work — a missing
        // bundle binary is a synchronous, cheap check and the alert must be on main anyway.
        let source = cliSourceURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            showAlert("Could not find harness-cli in the app bundle.")
            return false
        }

        // Capture path values before leaving the main actor (they are computed properties
        // on @MainActor types; they're cheap but must be read here, not inside detached).
        let cliDest = installedCLIPath
        let daemonDest = installedDaemonPath
        let binDir = binDirectory
        let daemonSrc = daemonSourceURL()

        // All file I/O and launchctl are done off the main actor so the menu (or Settings
        // "Install CLI" button) stays responsive while launchctl bootstraps the daemon.
        // The NSAlert is then shown back on main after the work completes.
        Task.detached {
            var alertMessage: String
            var success = false
            do {
                try HarnessPaths.ensureDirectories()
                try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
                try BinaryRefresher.copyExecutable(from: source, to: cliDest)
                var launchAgentMessage = ""
                if let daemon = daemonSrc {
                    do {
                        try BinaryRefresher.copyExecutable(from: daemon, to: daemonDest)
                        _ = try LaunchAgentInstaller.install(daemonPath: daemonDest)
                        launchAgentMessage = "\nHarnessDaemon installed to \(daemonDest.path)\nLaunchAgent installed at \(HarnessPaths.launchAgentURL.path)"
                    } catch {
                        launchAgentMessage = "\nLaunchAgent install failed: \(error)"
                    }
                }
                var completionMessage = ""
                if let lines = try? ShellCompletionInstaller.installForLoginShell(), !lines.isEmpty {
                    completionMessage = "\n" + lines.joined(separator: "\n")
                }
                alertMessage = """
                harness-cli installed to:
                \(cliDest.path)

                Add to your shell profile:
                export PATH="\(binDir.path):$PATH"\(launchAgentMessage)\(completionMessage)
                """
                success = true
            } catch {
                alertMessage = "Install failed: \(error.localizedDescription)"
            }
            // NSAlert presentation must be on the main actor.
            await MainActor.run {
                CLIInstaller.showAlert(alertMessage)
            }
            _ = success  // suppress unused-result warning; callers that need the return value
                         // should switch to the async variant if one is added in the future.
        }
        // The Task is fire-and-forget from the call site's perspective.  Return `true` to mean
        // "install was kicked off" — by the time any caller checks the value the alert will have
        // shown (or will shortly).  If a synchronous result is ever needed, expose an async API.
        return true
    }

    static func daemonSourceURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/HarnessDaemon")
        if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        #if DEBUG
        let debug = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/HarnessDaemon")
        if FileManager.default.fileExists(atPath: debug.path) { return debug }
        #endif
        return nil
    }

    static func cliSourceURL() -> URL {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/harness-cli")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        #if DEBUG
        let debug = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/harness-cli")
        if FileManager.default.fileExists(atPath: debug.path) {
            return debug
        }
        #endif
        return URL(fileURLWithPath: "/usr/local/bin/harness-cli")
    }

    private static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "harness-cli"
        alert.informativeText = message
        alert.runModal()
    }
}
