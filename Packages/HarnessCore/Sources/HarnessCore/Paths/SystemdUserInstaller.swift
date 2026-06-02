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
    public static func unitContents(daemonPath: URL, harnessHome: URL, logPath: URL) -> String {
        """
        [Unit]
        Description=Harness terminal daemon
        Documentation=https://github.com/robzilla1738/harness-terminal
        After=default.target

        [Service]
        Type=simple
        ExecStart=\(daemonPath.path)
        Environment=HARNESS_HOME=\(harnessHome.path)
        Restart=on-failure
        RestartSec=2
        StandardOutput=append:\(logPath.path)
        StandardError=append:\(logPath.path)

        [Install]
        WantedBy=default.target
        """
    }

    @discardableResult
    public func install(daemonPath: URL, harnessHome: URL = HarnessPaths.applicationSupport) throws -> ServiceInstallReport {
        guard FileManager.default.fileExists(atPath: daemonPath.path) else {
            throw LaunchAgentInstaller.InstallError.daemonNotFound(daemonPath)
        }
        try HarnessPaths.ensureDirectories()
        let unitURL = Self.unitURL
        try FileManager.default.createDirectory(
            at: unitURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let desired = Self.unitContents(daemonPath: daemonPath, harnessHome: harnessHome, logPath: HarnessPaths.daemonLogURL)
        let existed = FileManager.default.fileExists(atPath: unitURL.path)
        let existingContent = existed ? (try? String(contentsOf: unitURL, encoding: .utf8)) : nil
        let changed = existingContent != desired

        if changed {
            do {
                try desired.write(to: unitURL, atomically: true, encoding: .utf8)
            } catch {
                throw LaunchAgentInstaller.InstallError.writeFailed(unitURL, error)
            }
            _ = Self.runSystemctl(["daemon-reload"])
        }

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

    public func uninstall() {
        _ = Self.runSystemctl(["disable", "--now", Self.serviceName])
        try? FileManager.default.removeItem(at: Self.unitURL)
        _ = Self.runSystemctl(["daemon-reload"])
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.unitURL.path)
    }

    public func relaunch() {
        _ = Self.runSystemctl(["restart", Self.serviceName])
    }

    private static func runSystemctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        // `env` resolves systemctl on PATH across distros.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["systemctl", "--user"] + arguments
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-systemctl-\(UUID().uuidString).log")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            return (-1, "Failed to capture systemctl output")
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        do {
            try process.run()
        } catch {
            return (-1, "Failed to launch systemctl: \(error)")
        }
        process.waitUntilExit()
        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
