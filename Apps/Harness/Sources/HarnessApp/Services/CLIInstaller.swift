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
        let source = cliSourceURL()
        guard FileManager.default.fileExists(atPath: source.path) else {
            showAlert("Could not find harness-cli in the app bundle.")
            return false
        }
        do {
            try HarnessPaths.ensureDirectories()
            try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            try copyExecutable(source: source, destination: installedCLIPath)
            var launchAgentMessage = ""
            if let daemon = daemonSourceURL() {
                do {
                    try copyExecutable(source: daemon, destination: installedDaemonPath)
                    _ = try LaunchAgentInstaller.install(daemonPath: installedDaemonPath)
                    launchAgentMessage = "\nHarnessDaemon installed to \(installedDaemonPath.path)\nLaunchAgent installed at \(HarnessPaths.launchAgentURL.path)"
                } catch {
                    launchAgentMessage = "\nLaunchAgent install failed: \(error)"
                }
            }
            var completionMessage = ""
            if let lines = try? ShellCompletionInstaller.installForLoginShell(), !lines.isEmpty {
                completionMessage = "\n" + lines.joined(separator: "\n")
            }
            showAlert("""
            harness-cli installed to:
            \(installedCLIPath.path)

            Add to your shell profile:
            export PATH="\(binDirectory.path):$PATH"\(launchAgentMessage)\(completionMessage)
            """)
            return true
        } catch {
            showAlert("Install failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func copyExecutable(source: URL, destination: URL) throws {
        try BinaryRefresher.copyExecutable(from: source, to: destination)
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
