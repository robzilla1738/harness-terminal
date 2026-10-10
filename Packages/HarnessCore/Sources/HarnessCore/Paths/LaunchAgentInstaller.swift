#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Installs and manages the per-user LaunchAgent that supervises HarnessDaemon.
/// The daemon runs as a launchd-managed process so it survives Harness.app
/// quitting. Logout and reboot end live programs. Both Harness.app and
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
        case isolatedHome
        case serviceNotInactive
        case unexpectedService

        public var description: String {
            switch self {
            case let .daemonNotFound(url):
                return "HarnessDaemon executable not found at \(url.path)"
            case let .writeFailed(url, error):
                return "Failed to write LaunchAgent plist at \(url.path): \(error)"
            case let .launchctlFailed(code, output):
                return "launchctl exited with status \(code): \(output)"
            case .isolatedHome:
                return "An isolated Harness home must not change the user's managed service. Start HarnessDaemon directly for this home."
            case .serviceNotInactive:
                return "A live or uncertain session owner prevents service removal. Close its shells or explicitly stop the verified owner before uninstalling."
            case .unexpectedService:
                return "The service definition belongs to an unknown Harness home; removal was refused."
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
                <string>\(xmlText(daemonPath.path))</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HARNESS_HOME</key>
                <string>\(xmlText(harnessHome.path))</string>
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
            <string>\(xmlText(logPath.path))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlText(logPath.path))</string>
            <key>ThrottleInterval</key>
            <integer>5</integer>
        </dict>
        </plist>
        """
    }

    private static func xmlText(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Write the plist and bootstrap it into launchd. Idempotent: if the plist
    /// already exists with identical content and the service is loaded, this is
    /// a no-op. Changed definitions are staged. Explicit activation can boot out
    /// the old definition only after the prior owner has exited.
    @discardableResult
    public static func install(daemonPath: URL, harnessHome: URL = HarnessPaths.applicationSupport,
                               activateChanges: Bool = false) throws -> InstallReport {
        guard !HarnessPaths.hasHomeOverride else { throw InstallError.isolatedHome }
        guard [daemonPath, harnessHome, HarnessPaths.daemonLogURL].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && $0.path.utf8.count <= 4096 && !$0.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw InstallError.unexpectedService }
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

        if existed, changed, !activateChanges {
            try desired.write(to: plistURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8)
            return InstallReport(plistPath: plistURL, daemonPath: daemonPath,
                                 wasAlreadyInstalled: false, bootstrapped: false)
        }

        // The shared launchd label may currently supervise a different Harness home.
        // Never boot out that owner's programs while installing a new configuration.
        if existed {
            let priorHome: String? = existingContent.flatMap { text in
                guard let plist = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any],
                      let variables = plist["EnvironmentVariables"] as? [String: String] else { return nil }
                return variables["HARNESS_HOME"]
            }
            if priorHome.map({ URL(fileURLWithPath: $0).standardizedFileURL }) != harnessHome.standardizedFileURL {
                try desired.write(to: plistURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8)
                return InstallReport(plistPath: plistURL, daemonPath: daemonPath,
                                     wasAlreadyInstalled: false, bootstrapped: false)
            }
        }

        // Staging a service definition must never boot out a process that owns shells.
        // Adoption applies the staged definition after the daemon has actually stopped.
        if case .absent = DaemonOwnership.probe(home: harnessHome) {
            // Safe to install/activate below.
        } else {
            if changed {
                try desired.write(to: plistURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8)
            }
            return InstallReport(plistPath: plistURL, daemonPath: daemonPath,
                                 wasAlreadyInstalled: existed && !changed, bootstrapped: false)
        }

        let prepared = try DaemonInstanceLock.whileInactive(home: harnessHome) {
            if changed {
                if existed {
                    let stopped = runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
                    guard stopped.status == 0 || stopped.status == 3 || stopped.status == 113 else { throw InstallError.launchctlFailed(stopped.status, stopped.output) }
                }
                do {
                    try desired.write(to: plistURL, atomically: true, encoding: .utf8)
                } catch {
                    throw InstallError.writeFailed(plistURL, error)
                }
            }
        }
        guard prepared else {
            if changed { try desired.write(to: plistURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8) }
            return InstallReport(plistPath: plistURL, daemonPath: daemonPath,
                                 wasAlreadyInstalled: existed && !changed, bootstrapped: false)
        }
        try? FileManager.default.removeItem(at: plistURL.appendingPathExtension("pending"))

        let bootstrapResult = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        // `bootstrap` returns non-zero if the service is already loaded — that's
        // fine when the content matches. Treat status 37 (already-loaded) and 0
        // as success; surface other failures.
        let bootstrapped: Bool
        switch bootstrapResult.status {
        case 0:
            bootstrapped = true
        case 37: // service already bootstrapped
            bootstrapped = false
        default:
            throw InstallError.launchctlFailed(bootstrapResult.status, bootstrapResult.output)
        }
        let enabled = runLaunchctl(["enable", "gui/\(getuid())/\(HarnessPaths.launchAgentLabel)"])
        guard enabled.status == 0 else { throw InstallError.launchctlFailed(enabled.status, enabled.output) }
        return InstallReport(
            plistPath: plistURL,
            daemonPath: daemonPath,
            wasAlreadyInstalled: existed && !changed,
            bootstrapped: bootstrapped
        )
    }

    /// Service removal cannot implicitly stop programs or switch homes.
    public static func uninstall() throws {
        guard !HarnessPaths.hasHomeOverride else { throw InstallError.isolatedHome }
        let removed = try DaemonInstanceLock.whileInactive(home: HarnessPaths.applicationSupport) {
            let plistURL = HarnessPaths.launchAgentURL
            guard let data = try PrivateFile.read(plistURL) else { return }
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], values["Label"] as? String == HarnessPaths.launchAgentLabel,
                  (values["EnvironmentVariables"] as? [String: String])?["HARNESS_HOME"] == HarnessPaths.applicationSupport.path else { throw InstallError.unexpectedService }
            let result = runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
            guard result.status == 0 || result.status == 3 || result.status == 113 else { throw InstallError.launchctlFailed(result.status, result.output) }
            try FileManager.default.removeItem(at: plistURL)
            if try PrivateFile.read(plistURL.appendingPathExtension("pending")) != nil { try FileManager.default.removeItem(at: plistURL.appendingPathExtension("pending")) }
        }
        guard removed else { throw InstallError.serviceNotInactive }
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: HarnessPaths.launchAgentURL.path)
    }

    private static func runLaunchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        do {
            let result = try ProcessCapture.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: arguments, timeout: 10, maxOutputBytes: 64 * 1024)
            return (result.status, String(decoding: result.stdout + result.stderr, as: UTF8.self))
        } catch { return (-1, "launchctl: \(error.localizedDescription)") }
    }
}
