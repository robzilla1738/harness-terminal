import Foundation

/// Result of one `harness-cli doctor` check.
public enum DiagnosticStatus: String, Codable, Sendable, Equatable {
    case pass, warn, fail

    /// Fixed-width label for the text report (`[PASS]`/`[WARN]`/`[FAIL]`).
    public var label: String { rawValue.uppercased() }
}

/// One diagnostic row: what was checked, the verdict, and an actionable detail.
public struct DiagnosticCheck: Codable, Sendable, Equatable {
    public var name: String
    public var status: DiagnosticStatus
    public var detail: String

    public init(_ name: String, _ status: DiagnosticStatus, _ detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// The full `doctor` report. Exits nonzero only when something clearly failed (a misconfiguration
/// or security issue) — warnings (daemon not running, optional integrations absent) keep exit 0.
public struct DoctorReport: Codable, Sendable, Equatable {
    public var checks: [DiagnosticCheck]

    public init(checks: [DiagnosticCheck]) { self.checks = checks }

    /// Nonzero iff any check failed (warnings don't fail the command).
    public var exitCode: Int32 { checks.contains { $0.status == .fail } ? 1 : 0 }

    /// One `[STATUS] name — detail` line per check, for the default text output.
    public func text() -> [String] {
        checks.map { "[\($0.status.label)] \($0.name) — \($0.detail)" }
    }
}

/// Builds the `doctor` diagnostics. Pure and injectable: filesystem checks derive from `home`,
/// daemon reachability and installed agent hooks are passed in (the CLI computes them live; tests
/// supply deterministic values), so this never touches global state and is fully unit-testable.
public enum DoctorRunner {
    /// Run all checks against `home` (the Harness app-support root) with the supplied live signals.
    /// `daemonReachable` is the result of a `ping`; `cliPath` is the running executable's path;
    /// `installedAgentHooks` lists agents whose Harness hooks are installed (defaults to a live
    /// scan of the user's agent configs — tests pass an explicit value to avoid touching them).
    public static func run(
        home: URL = HarnessPaths.applicationSupport,
        daemonReachable: Bool,
        cliPath: String,
        installedAgentHooks: [AgentKind] = AgentHookInstaller.installableAgents.filter {
            AgentHookInstaller.isInstalled(agent: $0)
        }
    ) -> DoctorReport {
        var checks: [DiagnosticCheck] = []

        // 1. Daemon reachable. Not running is a normal state (it launches on demand), so warn.
        checks.append(daemonReachable
            ? .init("Daemon", .pass, "reachable (ping → pong)")
            : .init("Daemon", .warn, "not reachable — open Harness.app, or check launchctl print gui/$(id -u)/\(HarnessPaths.launchAgentLabel)"))

        // 2. Control socket: path must fit sun_path, and when present be owner-only (0o600).
        let socketURL = home.appendingPathComponent("harness.sock")
        if socketURL.path.utf8.count >= HarnessPaths.maxSocketPathLength {
            checks.append(.init("Control socket", .fail,
                "path is \(socketURL.path.utf8.count) bytes (max \(HarnessPaths.maxSocketPathLength - 1)) — shorten HARNESS_HOME: \(socketURL.path)"))
        } else if FileManager.default.fileExists(atPath: socketURL.path) {
            if let mode = posixMode(socketURL), mode & 0o077 != 0 {
                checks.append(.init("Control socket", .fail,
                    "is \(octal(mode)), not owner-only (0600) — any local user could drive the daemon. Restart the daemon or chmod 600 \(socketURL.path)"))
            } else {
                checks.append(.init("Control socket", .pass, "owner-only at \(socketURL.path)"))
            }
        } else {
            checks.append(.init("Control socket", .warn,
                daemonReachable
                    ? "not found at \(socketURL.path) though the daemon responded"
                    : "not found (created when the daemon starts): \(socketURL.path)"))
        }

        // 3. Harness home/config dir: when present must be owner-only (0o700) — it holds the
        //    socket, session layout, and hooks that run shell commands.
        if FileManager.default.fileExists(atPath: home.path) {
            if let mode = posixMode(home), mode & 0o077 != 0 {
                checks.append(.init("Home directory", .fail,
                    "\(home.path) is \(octal(mode)), not owner-only (0700) — another local user can read/tamper with it. chmod 700 \(home.path)"))
            } else {
                checks.append(.init("Home directory", .pass, "owner-only at \(home.path)"))
            }
        } else {
            checks.append(.init("Home directory", .warn, "not created yet (made on first daemon/app start): \(home.path)"))
        }

        // 4. CLI executable path (informational).
        checks.append(.init("CLI executable", .pass, cliPath))

        // 4b. Service supervision backend (launchd on macOS, systemd --user on Linux) + whether the
        //     daemon is installed to survive reboot/logout. The resolved socket path is reported too,
        //     since on Linux it can live under $XDG_RUNTIME_DIR rather than the home.
        let installer = ServiceInstallers.current
        checks.append(installer.isInstalled
            ? .init("Service (\(installer.backendName))", .pass, "installed; socket \(HarnessPaths.socketURL.path)")
            : .init("Service (\(installer.backendName))", .warn,
                "not installed — run: harness-cli install (socket \(HarnessPaths.socketURL.path))"))

        // 5. Shell integration (optional): any per-shell OSC 133 script written under the home.
        let integrationDir = home.appendingPathComponent("shell-integration", isDirectory: true)
        let installedShells = ShellIntegration.Shell.allCases.filter {
            FileManager.default.fileExists(atPath: integrationDir.appendingPathComponent("harness.\($0.rawValue)").path)
        }
        checks.append(installedShells.isEmpty
            ? .init("Shell integration", .warn, "not installed — run: harness-cli install-shell-integration")
            : .init("Shell integration", .pass, "installed for \(installedShells.map(\.rawValue).joined(separator: ", "))"))

        // 6. Notifications (best-effort from the CLI; macOS auth is GUI-only). Report the setting
        //    when app support exists; absent settings mean Harness hasn't been configured yet.
        let settingsURL = home.appendingPathComponent("settings.json")
        if let data = try? Data(contentsOf: settingsURL),
           let settings = try? JSONDecoder().decode(HarnessSettings.self, from: data) {
            checks.append(settings.systemNotificationsEnabled
                ? .init("Notifications", .pass, "enabled in settings (system banner authorization is managed by Harness.app)")
                : .init("Notifications", .warn, "disabled in settings (systemNotificationsEnabled = false)"))
        } else {
            checks.append(.init("Notifications", .warn, "Harness not configured yet (no settings.json) — open Harness.app once"))
        }

        // 7. Agent hooks (optional): which installable agents have Harness notification hooks.
        checks.append(installedAgentHooks.isEmpty
            ? .init("Agent hooks", .warn, "none installed — run: harness-cli install-hooks <agent>")
            : .init("Agent hooks", .pass, "installed for \(installedAgentHooks.map(\.displayName).joined(separator: ", "))"))

        return DoctorReport(checks: checks)
    }

    private static func posixMode(_ url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.posixPermissions] as? NSNumber)?.intValue
    }

    private static func octal(_ mode: Int) -> String {
        "0" + String(mode & 0o777, radix: 8)
    }
}
