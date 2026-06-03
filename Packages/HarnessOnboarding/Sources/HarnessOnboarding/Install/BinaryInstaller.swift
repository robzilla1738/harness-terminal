import Foundation
import AppKit

/// The one-click installer logic for the standalone Harness CLI onboarding experience.
///
/// It is deliberately self-contained (no link to HarnessCore) but follows the exact
/// same paths, plist template, and launchctl patterns as the real `harness-cli install`
/// and `LaunchAgentInstaller` so that the result is 100% compatible with a future
/// full Harness.app or CLI-only distribution.
@MainActor
enum BinaryInstaller {
    enum DetectionStatus: Equatable {
        case found(version: String?, path: URL)
        case willInstall
        case notFound

        var display: String {
            switch self {
            // Fall back to the detected binary's name so the Daemon row reads "Found HarnessDaemon"
            // — not the CLI's "Found harness-cli" (both rows pass version: nil today).
            case .found(let v, let path): "Found \(v ?? path.lastPathComponent)"
            case .willInstall: "Will install"
            case .notFound: "Not found in common locations"
            }
        }

        var isReady: Bool {
            switch self {
            case .found, .willInstall: true
            case .notFound: false
            }
        }
    }

    struct InstallReport {
        let cliInstalled: Bool
        let daemonInstalled: Bool
        let launchAgentInstalled: Bool
        let messages: [String]
    }

    enum InstallError: LocalizedError {
        case missingBundledTools(messages: [String])

        var errorDescription: String? {
            switch self {
            case .missingBundledTools(let messages):
                return (messages + ["Harness.app is missing its bundled command-line tools. Rebuild or reinstall Harness."])
                    .joined(separator: "\n")
            }
        }
    }

    // MARK: - Detection (the locations the real harness-cli install also checks)

    /// The `Contents/MacOS` directory of the host app. Embedded in Harness.app this is where
    /// the bundled `harness-cli` + `HarnessDaemon` live (copied in by the "Copy Bundled Tools"
    /// build step), so the Install step copies straight out of the running bundle.
    private static var bundledMacOSDir: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent()
    }

    static func detectCLI() -> DetectionStatus {
        let candidates: [URL] = [
            // 1. Inside the running app bundle's MacOS dir (Harness.app embeds the binaries)
            bundledMacOSDir?.appendingPathComponent("harness-cli"),
            // 2. Next to the app (the "all-in-one DMG" layout)
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("harness-cli"),
            // 3. Inside a sibling Harness.app (if the user has the GUI version)
            URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/harness-cli"),
            // 4. Already installed by a previous run or the GUI app
            HarnessCLIPaths.installedCLIPath,
            // 5. Dev builds
            URL(fileURLWithPath: ".build/release/harness-cli", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        ].compactMap { $0 }

        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                // Best-effort version (the real binary prints nothing on --version today,
                // so we just report the path; the UI shows "Found").
                return .found(version: nil, path: url)
            }
        }
        return .willInstall   // we will copy from the best candidate we can find at install time
    }

    static func detectDaemon() -> DetectionStatus {
        let candidates: [URL] = [
            bundledMacOSDir?.appendingPathComponent("HarnessDaemon"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("HarnessDaemon"),
            URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/HarnessDaemon"),
            HarnessCLIPaths.installedDaemonPath,
            URL(fileURLWithPath: ".build/release/HarnessDaemon", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        ].compactMap { $0 }
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return .found(version: nil, path: url)
            }
        }
        return .willInstall
    }

    // MARK: - The actual install (idempotent, user-friendly)

    static func performInstall(cliSource: URL?, daemonSource: URL?) throws -> InstallReport {
        var messages: [String] = []
        var cliOK = false
        var daemonOK = false
        var agentOK = false

        try HarnessCLIPaths.ensureDirectories()

        // Copy CLI
        if let src = cliSource ?? findBestSource(named: "harness-cli") {
            let dest = HarnessCLIPaths.installedCLIPath
            try copyReplacing(src: src, dest: dest, executable: true)
            messages.append("harness-cli → \(dest.path)")
            cliOK = true
        } else {
            messages.append("harness-cli source not found; skipping binary copy")
        }

        // Copy Daemon
        if let src = daemonSource ?? findBestSource(named: "HarnessDaemon") {
            let dest = HarnessCLIPaths.installedDaemonPath
            try copyReplacing(src: src, dest: dest, executable: true)
            messages.append("HarnessDaemon → \(dest.path)")
            daemonOK = true
        } else {
            messages.append("HarnessDaemon source not found; skipping binary copy")
        }

        guard cliOK, daemonOK else {
            throw InstallError.missingBundledTools(messages: messages)
        }

        // LaunchAgent (always try; uses the exact template we captured from the real installer)
        if daemonOK || FileManager.default.fileExists(atPath: HarnessCLIPaths.installedDaemonPath.path) {
            let daemonPath = HarnessCLIPaths.installedDaemonPath
            let home = HarnessCLIPaths.applicationSupport
            let log = home.appendingPathComponent("logs/daemon.log")
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)

            let plistContent = launchAgentPlist(daemonPath: daemonPath, harnessHome: home, logPath: log)
            let plistURL = HarnessCLIPaths.launchAgentURL
            try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            let existed = FileManager.default.fileExists(atPath: plistURL.path)
            let changed = (try? String(contentsOf: plistURL, encoding: .utf8)) != plistContent

            if changed {
                if existed {
                    _ = runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
                }
                try plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
            }

            let result = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            if result.status == 0 || result.status == 37 || result.status == 5 {
                agentOK = true
                messages.append("LaunchAgent installed → \(plistURL.path)")
            } else {
                messages.append("LaunchAgent bootstrap returned \(result.status): \(result.output)")
            }
            _ = runLaunchctl(["enable", "gui/\(getuid())/\(HarnessCLIPaths.launchAgentLabel)"])
        } else {
            messages.append("No daemon binary available — LaunchAgent not installed")
        }

        return InstallReport(
            cliInstalled: cliOK,
            daemonInstalled: daemonOK,
            launchAgentInstalled: agentOK,
            messages: messages
        )
    }

    // MARK: - Helpers

    private static func findBestSource(named binary: String) -> URL? {
        if let bundled = bundledMacOSDir?.appendingPathComponent(binary),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }

        let relative = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(binary)
        if FileManager.default.fileExists(atPath: relative.path) { return relative }

        let app = URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/\(binary)")
        if FileManager.default.fileExists(atPath: app.path) { return app }

        return nil
    }

    private static func copyReplacing(src: URL, dest: URL, executable: Bool) throws {
        if src.standardizedFileURL.path == dest.standardizedFileURL.path {
            if executable {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            }
            return
        }
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    /// The exact plist template captured from the real LaunchAgentInstaller at project creation.
    private static func launchAgentPlist(daemonPath: URL, harnessHome: URL, logPath: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HarnessCLIPaths.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath.path)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HARNESS_HOME</key>
                <string>\(harnessHome.path)</string>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
                <key>Crashed</key>
                <true/>
            </dict>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(logPath.path)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath.path)</string>
            <key>ThrottleInterval</key>
            <integer>5</integer>
        </dict>
        </plist>
        """
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        process.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
