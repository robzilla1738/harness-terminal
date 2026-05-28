import AppKit
import Foundation
import HarnessCore

@MainActor
enum CLIInstaller {
    static var binDirectory: URL {
        HarnessPaths.applicationSupport.appendingPathComponent("bin", isDirectory: true)
    }

    static var installedCLIPath: URL {
        binDirectory.appendingPathComponent("harness-cli")
    }

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
            if FileManager.default.fileExists(atPath: installedCLIPath.path) {
                try FileManager.default.removeItem(at: installedCLIPath)
            }
            try FileManager.default.copyItem(at: source, to: installedCLIPath)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedCLIPath.path)
            var launchAgentMessage = ""
            if let daemon = daemonSourceURL() {
                do {
                    _ = try LaunchAgentInstaller.install(daemonPath: daemon)
                    launchAgentMessage = "\nLaunchAgent installed at \(HarnessPaths.launchAgentURL.path)"
                } catch {
                    launchAgentMessage = "\nLaunchAgent install failed: \(error)"
                }
            }
            var completionMessage = ""
            if let url = try? ShellCompletionInstaller.installFishCompletion() {
                completionMessage = "\nFish completion installed at \(url.path)"
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

enum FirstRunExperience {
    static func offerCLIInstallIfNeeded() {
        let key = "HarnessOfferedCLIInstall"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let alert = NSAlert()
            alert.messageText = "Install harness-cli?"
            alert.informativeText = "Add harness-cli to your PATH for agent hooks and automation."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                CLIInstaller.install()
            }
        }
    }
}
