#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Installs and manages the per-user LaunchAgent that supervises HarnessDaemon.
/// The daemon runs as a launchd-managed process so it survives Harness.app
/// quitting, system logout, and macOS user-session reboot. Both Harness.app and
/// `harness-cli install` use the same installer so behavior is consistent.
public enum LaunchAgentInstaller {
    public struct InstallReport: Sendable {
        public let plistPath: URL
        public let daemonPath: URL
        public let wasAlreadyInstalled: Bool
        public let bootstrapped: Bool
    }

    public enum InstallError: Error, CustomStringConvertible {
        case daemonNotFound(URL)
        case writeFailed(URL, Error)
        case launchctlFailed(Int32, String)

        public var description: String {
            switch self {
            case let .daemonNotFound(url):
                return "HarnessDaemon executable not found at \(url.path)"
            case let .writeFailed(url, error):
                return "Failed to write LaunchAgent plist at \(url.path): \(error)"
            case let .launchctlFailed(code, output):
                return "launchctl exited with status \(code): \(output)"
            }
        }
    }

    public static func plist(daemonPath: URL, harnessHome: URL, logPath: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HarnessPaths.launchAgentLabel)</string>
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

    /// Write the plist and bootstrap it into launchd. Idempotent: if the plist
    /// already exists with identical content and the service is loaded, this is
    /// a no-op. If content differs, we `bootout` the old service first so the
    /// new configuration takes effect.
    @discardableResult
    public static func install(daemonPath: URL, harnessHome: URL = HarnessPaths.applicationSupport) throws -> InstallReport {
        guard FileManager.default.fileExists(atPath: daemonPath.path) else {
            throw InstallError.daemonNotFound(daemonPath)
        }
        try HarnessPaths.ensureDirectories()
        let plistURL = HarnessPaths.launchAgentURL
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let logURL = HarnessPaths.daemonLogURL
        let desired = plist(daemonPath: daemonPath, harnessHome: harnessHome, logPath: logURL)
        let existed = FileManager.default.fileExists(atPath: plistURL.path)
        let existingContent = existed ? (try? String(contentsOf: plistURL, encoding: .utf8)) : nil
        let changed = existingContent != desired

        if changed {
            if existed {
                _ = runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
            }
            do {
                try desired.write(to: plistURL, atomically: true, encoding: .utf8)
            } catch {
                throw InstallError.writeFailed(plistURL, error)
            }
        }

        let bootstrapResult = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        // `bootstrap` returns non-zero if the service is already loaded — that's
        // fine when the content matches. Treat status 37 (already-loaded) and 0
        // as success; surface other failures.
        let bootstrapped: Bool
        switch bootstrapResult.status {
        case 0:
            bootstrapped = true
        case 37, 5: // service already bootstrapped / busy
            bootstrapped = false
        default:
            throw InstallError.launchctlFailed(bootstrapResult.status, bootstrapResult.output)
        }
        _ = runLaunchctl(["enable", "gui/\(getuid())/\(HarnessPaths.launchAgentLabel)"])
        return InstallReport(
            plistPath: plistURL,
            daemonPath: daemonPath,
            wasAlreadyInstalled: existed && !changed,
            bootstrapped: bootstrapped
        )
    }

    /// Tear down and remove. Used by an uninstaller. Best-effort; failure on a
    /// missing service is not an error.
    public static func uninstall() {
        let plistURL = HarnessPaths.launchAgentURL
        _ = runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HarnessPaths.launchAgentURL.path)
    }

    /// Ask launchd to relaunch the daemon (used after the app updates and the
    /// daemon executable on disk changes). Best-effort.
    public static func relaunch() {
        _ = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(HarnessPaths.launchAgentLabel)"])
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch /bin/launchctl: \(error)")
        }
        process.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
