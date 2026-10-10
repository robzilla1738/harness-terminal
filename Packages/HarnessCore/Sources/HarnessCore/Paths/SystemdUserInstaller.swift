import Foundation

/// Linux systemd `--user` backend: installs `~/.config/systemd/user/harness-daemon.service` and
/// enables+starts it, so the daemon survives logout (with lingering) and restarts on failure.
/// Mirrors `LaunchAgentInstaller`'s idempotent write-if-changed + shell-out structure.
public struct SystemdUserInstaller: ServiceInstaller {
    public static let serviceName = "harness-daemon.service"
    public init() {}
    public var backendName: String { "systemd --user" }

    public static var unitURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/systemd/user", isDirectory: true)
            .appendingPathComponent(serviceName)
    }

    /// The generated unit. `Type=simple` with the daemon in the foreground (it calls `dispatchMain`),
    /// restarted on failure, logging to the daemon log. `HARNESS_HOME` is pinned so the service and
    /// interactive `harness-cli` resolve the same socket/sessions.
    public static func unitContents(daemonPath: URL, harnessHome: URL, logPath: URL) throws -> String {
        guard [daemonPath, harnessHome, logPath].allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && $0.path.utf8.count <= 4096 && !$0.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { throw LaunchAgentInstaller.InstallError.unexpectedService }
        return """
        [Unit]
        Description=Harness terminal daemon
        Documentation=https://github.com/robzilla1738/harness-terminal
        After=default.target

        [Service]
        Type=simple
        ExecStart=:\(quoted(daemonPath.path))
        Environment=\(quoted("HARNESS_HOME=" + harnessHome.path))
        Restart=on-failure
        RestartSec=2
        StandardOutput=append:\(logPath.path.replacingOccurrences(of: "%", with: "%%"))
        StandardError=append:\(logPath.path.replacingOccurrences(of: "%", with: "%%"))

        [Install]
        WantedBy=default.target
        """
    }
    private static func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%") + "\"" }
    private static func hasRecordedHome(_ contents: String, home: URL) -> Bool {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.contains(Substring("Environment=" + quoted("HARNESS_HOME=" + home.path))) || lines.contains(Substring("Environment=HARNESS_HOME=" + home.path))
    }

    @discardableResult
    public func install(daemonPath: URL, harnessHome: URL = HarnessPaths.applicationSupport) throws -> ServiceInstallReport {
        try prepare(daemonPath: daemonPath, harnessHome: harnessHome, activateChanges: false)
    }

    public func activate(daemonPath: URL, harnessHome: URL = HarnessPaths.applicationSupport) throws -> ServiceInstallReport {
        try prepare(daemonPath: daemonPath, harnessHome: harnessHome, activateChanges: true)
    }

    private func prepare(daemonPath: URL, harnessHome: URL, activateChanges: Bool) throws -> ServiceInstallReport {
        guard !HarnessPaths.hasHomeOverride else { throw LaunchAgentInstaller.InstallError.isolatedHome }
        guard FileManager.default.fileExists(atPath: daemonPath.path) else {
            throw LaunchAgentInstaller.InstallError.daemonNotFound(daemonPath)
        }
        try HarnessPaths.ensureDirectories()
        let unitURL = Self.unitURL
        try FileManager.default.createDirectory(
            at: unitURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let desired = try Self.unitContents(daemonPath: daemonPath, harnessHome: harnessHome, logPath: HarnessPaths.daemonLogURL)
        let existed = FileManager.default.fileExists(atPath: unitURL.path)
        let existingContent = existed ? (try? String(contentsOf: unitURL, encoding: .utf8)) : nil
        let changed = existingContent != desired

        if existed, changed, !activateChanges {
            try desired.write(to: unitURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8)
            return ServiceInstallReport(unitPath: unitURL, daemonPath: daemonPath,
                                        wasAlreadyInstalled: false, activated: false)
        }

        if existed, !Self.hasRecordedHome(existingContent ?? "", home: harnessHome) {
            // Preserve service definitions for other/unknown homes; editing a shared
            // unit must not implicitly switch the owner of an active service.
            try desired.write(to: unitURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8)
            return ServiceInstallReport(unitPath: unitURL, daemonPath: daemonPath,
                                        wasAlreadyInstalled: false, activated: false)
        }

        if case .absent = DaemonOwnership.probe(home: harnessHome) {
            // Safe to install/activate below.
        } else {
            if changed {
                try desired.write(to: unitURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8)
            }
            return ServiceInstallReport(unitPath: unitURL, daemonPath: daemonPath,
                                        wasAlreadyInstalled: existed && !changed, activated: false)
        }

        let prepared = try DaemonInstanceLock.whileInactive(home: harnessHome) {
            if changed {
                do {
                    try desired.write(to: unitURL, atomically: true, encoding: .utf8)
                } catch {
                    throw LaunchAgentInstaller.InstallError.writeFailed(unitURL, error)
                }
                let reload = Self.runSystemctl(["daemon-reload"])
                guard reload.status == 0 else { throw LaunchAgentInstaller.InstallError.launchctlFailed(reload.status, "systemd reload: " + reload.output) }
            }
        }
        guard prepared else {
            if changed { try desired.write(to: unitURL.appendingPathExtension("pending"), atomically: true, encoding: .utf8) }
            return ServiceInstallReport(unitPath: unitURL, daemonPath: daemonPath,
                                        wasAlreadyInstalled: existed && !changed, activated: false)
        }
        try? FileManager.default.removeItem(at: unitURL.appendingPathExtension("pending"))

        // `enable --now` installs the wants-symlink and starts the unit; idempotent.
        let result = Self.runSystemctl(["enable", "--now", Self.serviceName])
        let activated = result.status == 0
        if !activated {
            // Non-fatal: surface the systemctl output (e.g. "Failed to connect to bus" on a host with
            // no user session) but leave the unit installed so a later `systemctl --user` works.
            fputs("harness: `systemctl --user enable --now \(Self.serviceName)` failed: \(result.output)\n", harnessStderr)
            fputs("harness: if this is a headless host, run `loginctl enable-linger $USER` and retry.\n", harnessStderr)
        }
        return ServiceInstallReport(
            unitPath: unitURL,
            daemonPath: daemonPath,
            wasAlreadyInstalled: existed && !changed,
            activated: activated
        )
    }

    public func uninstall() throws {
        guard !HarnessPaths.hasHomeOverride else { throw LaunchAgentInstaller.InstallError.isolatedHome }
        let removed = try DaemonInstanceLock.whileInactive(home: HarnessPaths.applicationSupport) {
            guard let data = try PrivateFile.read(Self.unitURL) else { return }
            let contents = String(decoding: data, as: UTF8.self)
            guard Self.hasRecordedHome(contents, home: HarnessPaths.applicationSupport) else { throw LaunchAgentInstaller.InstallError.unexpectedService }
            let result = Self.runSystemctl(["disable", "--now", Self.serviceName])
            guard result.status == 0 else { throw LaunchAgentInstaller.InstallError.launchctlFailed(result.status, "systemd: " + result.output) }
            try FileManager.default.removeItem(at: Self.unitURL)
            if try PrivateFile.read(Self.unitURL.appendingPathExtension("pending")) != nil { try FileManager.default.removeItem(at: Self.unitURL.appendingPathExtension("pending")) }
            let reload = Self.runSystemctl(["daemon-reload"])
            guard reload.status == 0 else { throw LaunchAgentInstaller.InstallError.launchctlFailed(reload.status, "systemd reload: " + reload.output) }
        }
        guard removed else { throw LaunchAgentInstaller.InstallError.serviceNotInactive }
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.unitURL.path)
    }


    private static func runSystemctl(_ arguments: [String]) -> (status: Int32, output: String) {
        do {
            let result = try ProcessCapture.run(URL(fileURLWithPath: "/usr/bin/env"), arguments: ["systemctl", "--user"] + arguments, timeout: 10, maxOutputBytes: 64 * 1024)
            return (result.status, String(decoding: result.stdout + result.stderr, as: UTF8.self))
        } catch { return (-1, "systemctl: \(error.localizedDescription)") }
    }
}
