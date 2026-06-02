import Foundation

/// Result of installing the daemon as a managed service.
public struct ServiceInstallReport: Sendable {
    /// The service definition file: a launchd plist on macOS, a systemd `.service` on Linux.
    public let unitPath: URL
    public let daemonPath: URL
    public let wasAlreadyInstalled: Bool
    /// Whether the service was (re)activated — bootstrapped (launchd) or enabled+started (systemd).
    public let activated: Bool

    public init(unitPath: URL, daemonPath: URL, wasAlreadyInstalled: Bool, activated: Bool) {
        self.unitPath = unitPath
        self.daemonPath = daemonPath
        self.wasAlreadyInstalled = wasAlreadyInstalled
        self.activated = activated
    }
}

/// Installs and supervises HarnessDaemon as a per-user background service. Implemented by a launchd
/// backend on macOS and a systemd-user backend on Linux, so the same `harness install` flow brings
/// the daemon up on a headless box (issue #16) as on a Mac.
public protocol ServiceInstaller: Sendable {
    @discardableResult
    func install(daemonPath: URL, harnessHome: URL) throws -> ServiceInstallReport
    func uninstall()
    var isInstalled: Bool { get }
    func relaunch()
    /// Human-readable backend name for diagnostics ("launchd" / "systemd --user").
    var backendName: String { get }
}

/// The service installer for the current platform.
public enum ServiceInstallers {
    public static var current: ServiceInstaller {
        #if os(macOS)
        return LaunchdServiceInstaller()
        #else
        return SystemdUserInstaller()
        #endif
    }
}

/// macOS launchd backend — a thin `ServiceInstaller` over the existing `LaunchAgentInstaller`
/// (kept as-is so the GUI's `DaemonLauncher` and earlier callers are unaffected).
public struct LaunchdServiceInstaller: ServiceInstaller {
    public init() {}
    public var backendName: String { "launchd" }

    @discardableResult
    public func install(daemonPath: URL, harnessHome: URL = HarnessPaths.applicationSupport) throws -> ServiceInstallReport {
        let report = try LaunchAgentInstaller.install(daemonPath: daemonPath, harnessHome: harnessHome)
        return ServiceInstallReport(
            unitPath: report.plistPath,
            daemonPath: report.daemonPath,
            wasAlreadyInstalled: report.wasAlreadyInstalled,
            activated: report.bootstrapped
        )
    }

    public func uninstall() { LaunchAgentInstaller.uninstall() }
    public var isInstalled: Bool { LaunchAgentInstaller.isInstalled }
    public func relaunch() { LaunchAgentInstaller.relaunch() }
}
