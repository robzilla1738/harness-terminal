import Darwin
import Foundation
import HarnessCore

/// Connects the app to the long-lived `HarnessDaemon` process. The daemon is
/// owned by launchd (installed by `LaunchAgentInstaller`) in release builds so it
/// survives `Harness.app` quitting, logout, and reboot. The launcher's job is to
/// *find* a running daemon and, if none, start one — fast and without freezing the
/// UI. Release builds prefer launchd first so the daemon is supervised from the
/// start; debug builds and launchd failures fall back to a directly-spawned child.
///
/// **Startup must never block the main thread.** `ensureRunning(then:)` runs the
/// whole discover→install→poll dance on a background queue and calls back on the
/// main thread once the daemon answers (or gives up). The strategy is
/// *launchd-first in release*: if a quick ping fails we install/bootstrap the
/// LaunchAgent and let launchd bring the daemon up, so it is launchd-owned and
/// supervised from the start. Installing first also rewrites a stale LaunchAgent
/// path (e.g. a DerivedData path from a previous Xcode build that no longer
/// exists) instead of running a directly-spawned daemon *underneath* a launchd
/// service that then retries every throttle interval. A directly-spawned child is
/// the fallback only when launchd cannot bring one up — and is the normal path in
/// DEBUG, which skips the LaunchAgent entirely.
///
/// @unchecked Sendable: launch/poll state is confined to the serial `queue`.
final class DaemonLauncher: @unchecked Sendable {
    static let shared = DaemonLauncher()

    private var fallbackProcess: Process?
    private let queue = DispatchQueue(label: "com.robert.harness.daemon-launcher")

    private init() {}

    /// Ensure a daemon is reachable, off the main thread. `completion` runs on the
    /// main thread with `true` if the daemon answers. Safe to call at launch — the
    /// UI can build immediately and refresh from the callback.
    func ensureRunning(then completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        queue.async { [weak self] in
            let ok = self?.ensureRunningBlocking() ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(ok) } }
        }
    }

    /// Synchronous variant for non-main callers/tests. Never call from the main thread.
    @discardableResult
    func ensureRunningBlocking() -> Bool {
        // Refresh the installed bin/ copies before any staleness check so the restart below
        // brings up the *updated* daemon. Release-only: a DEBUG build must never clobber the
        // user's installed release binaries (the bin/ copies and the LaunchAgent label are
        // global — not isolated by HARNESS_HOME).
        #if !DEBUG
        refreshInstalledBinaries()
        #endif
        if let stats = daemonStats(timeout: 0.4) {
            if daemonIsStale(stats) {
                restartStaleDaemon()
                if pollUntilFreshDaemon(replacingPID: stats.pid, timeoutSeconds: 3) { return true }
            } else {
                return true
            }
        } else if daemonResponds(timeout: 0.2) {
            // A daemon old enough to not understand `daemonStats` may still
            // answer `ping`, which is not enough for newer app/CLI features.
            // Restart it through the installed LaunchAgent and wait for a
            // daemon that can report stats before declaring startup ready.
            let stalePID = daemonPIDFromFile()
            restartStaleDaemon()
            if pollUntilFreshDaemon(replacingPID: stalePID, timeoutSeconds: 3) { return true }
        }

        // In release, install the corrected LaunchAgent before falling back. This
        // fixes stale DerivedData/App bundle paths and avoids running a fallback
        // daemon underneath a launchd service that then retries every throttle
        // interval.
        #if !DEBUG
        if installLaunchAgentIfPossible(), pollUntilResponding(timeoutSeconds: 4) { return true }
        #endif

        spawnFallbackProcess()
        if pollUntilResponding(timeoutSeconds: 3) { return true }
        return false
    }

    private func daemonResponds(timeout: TimeInterval = 0.5) -> Bool {
        guard let response = try? DaemonClient().request(.ping, timeout: timeout) else { return false }
        if case .pong = response { return true }
        return false
    }

    private func daemonStats(timeout: TimeInterval = 0.5) -> DaemonStats? {
        guard let response = try? DaemonClient().request(.daemonStats, timeout: timeout),
              case let .daemonStats(stats) = response
        else { return nil }
        return stats
    }

    /// A running daemon is stale when its build handshake disagrees with this app's build
    /// (nil = a daemon too old to report one), or — for the dev loop, where the build constant
    /// doesn't change between rebuilds — when the bundled binary is newer than the daemon's
    /// start. The handshake is authoritative: it survives daemon restarts, which reset the
    /// start time the mtime heuristic compares against and made it permanently read "fresh".
    private func daemonIsStale(_ stats: DaemonStats) -> Bool {
        if stats.isStale(comparedTo: HarnessVersion.build) { return true }
        return bundledDaemonIsNewer(than: stats)
    }

    private func bundledDaemonIsNewer(than stats: DaemonStats) -> Bool {
        guard let executable = daemonExecutableURL(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let modifiedAt = attributes[.modificationDate] as? Date
        else { return false }
        let daemonStartedAt = Date().addingTimeInterval(-stats.uptimeSeconds)
        return modifiedAt > daemonStartedAt.addingTimeInterval(1)
    }

    /// Restart the daemon **exactly once**. `install()` already bootouts-on-change + bootstraps, so a
    /// changed plist path (daemon moved on disk) starts the fresh daemon itself; only an *unchanged*
    /// path (the same binary rebuilt in place — the common Xcode dev loop) needs a single
    /// `relaunch()` kick. The old `install() + relaunch() + kill(pid)` combo fired 2–3 restarts,
    /// re-running `ensureAllSnapshotSurfaces` each time and widening the window where a pane reconnect
    /// could subscribe to a momentarily-missing surface and freeze.
    private func restartStaleDaemon() {
        guard let executable = launchAgentDaemonTarget(),
              let report = try? LaunchAgentInstaller.install(daemonPath: executable)
        else {
            // No installable LaunchAgent (e.g. daemon binary not found) — best-effort kick.
            LaunchAgentInstaller.relaunch()
            fallbackProcess = nil
            return
        }
        if report.wasAlreadyInstalled {
            LaunchAgentInstaller.relaunch()
        }
        fallbackProcess = nil
    }

    private func pollUntilResponding(timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if daemonResponds(timeout: 0.3) { return true }
            // Thread.sleep is preferred over usleep here: both park the calling thread for
            // 100 ms, but Thread.sleep carries clearer intent and integrates better with the
            // Swift runtime's thread accounting. These polls run exclusively on `queue` — a
            // private serial DispatchQueue — so blocking its one worker thread for up to ~4 s
            // is intentional and bounded; no other work is queued behind them.
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func pollUntilFreshDaemon(replacingPID oldPID: Int32?, timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let stats = daemonStats(timeout: 0.3),
               oldPID.map({ stats.pid != $0 }) ?? true,
               !daemonIsStale(stats) {
                return true
            }
            // Same rationale as pollUntilResponding: Thread.sleep over usleep, serial queue,
            // bounded duration.
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func daemonPIDFromFile() -> Int32? {
        guard let raw = try? String(contentsOf: HarnessPaths.daemonPIDURL, encoding: .utf8) else {
            return nil
        }
        return Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func installLaunchAgentIfPossible() -> Bool {
        guard let executable = launchAgentDaemonTarget() else { return false }
        do {
            _ = try LaunchAgentInstaller.install(daemonPath: executable)
            return true
        } catch {
            fputs("Harness: LaunchAgent install failed: \(error) — using in-process daemon\n", harnessStderr)
            return false
        }
    }

    private func spawnFallbackProcess() {
        // Don't stack duplicate spawns if a previous one is still coming up.
        if let existing = fallbackProcess, existing.isRunning { return }
        guard let executable = daemonExecutableURL() else {
            fputs("Harness: could not locate HarnessDaemon executable\n", harnessStderr)
            return
        }
        let proc = Process()
        proc.executableURL = executable
        proc.standardOutput = nil
        proc.standardError = nil
        var environment = ProcessInfo.processInfo.environment
        environment["HARNESS_HOME"] = HarnessPaths.applicationSupport.path
        proc.environment = environment
        try? HarnessPaths.ensureDirectories()
        do {
            try proc.run()
            fallbackProcess = proc
        } catch {
            fputs("Harness: failed to spawn HarnessDaemon at \(executable.path): \(error)\n", harnessStderr)
        }
    }

    /// Refresh the installed `bin/` daemon + CLI from this app bundle so an app update actually
    /// advances the launchd-supervised daemon and the on-PATH CLI (issue #60 — Sparkle replaces
    /// the bundle copies, never these). Only refreshes copies an installer already created, and
    /// only when bytes differ, so the common up-to-date case is just a content compare and the
    /// refresh→restart happens at most once per update.
    private func refreshInstalledBinaries() {
        _ = try? BinaryRefresher.refreshIfChanged(
            source: bundledBinaryURL(named: "HarnessDaemon"),
            destination: BinaryRefresher.installedDaemonPath
        )
        _ = try? BinaryRefresher.refreshIfChanged(
            source: bundledBinaryURL(named: "harness-cli"),
            destination: BinaryRefresher.installedCLIPath
        )
    }

    /// A binary shipped next to the app executable (`Contents/MacOS/`), where the release
    /// packager puts both the daemon and the CLI.
    private func bundledBinaryURL(named name: String) -> URL? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let url = dir.appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// The daemon the LaunchAgent should supervise: the installed AppSupport copy when present
    /// (canonical — what onboarding/`harness-cli install` write, survives the app moving, and
    /// just refreshed above in release), else wherever the bundle/dev daemon lives. DEBUG keeps
    /// the bundle/dev path so the Xcode loop restarts into the freshly built daemon, not a
    /// previously installed release copy.
    private func launchAgentDaemonTarget() -> URL? {
        #if !DEBUG
        let installed = BinaryRefresher.installedDaemonPath
        if FileManager.default.isExecutableFile(atPath: installed.path) { return installed }
        #endif
        return daemonExecutableURL()
    }

    /// Locate the daemon binary across every layout we ship in:
    /// 1. inside the app bundle (`Contents/MacOS/HarnessDaemon`, copied by the
    ///    release packager and the Xcode post-build script),
    /// 2. next to the app bundle (Xcode `BUILT_PRODUCTS_DIR` sibling),
    /// 3. the SwiftPM debug build dir (`.build/debug`),
    /// 4. a system install path.
    private func daemonExecutableURL() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("HarnessDaemon"))
        }
        // Sibling of Harness.app — where Xcode drops the HarnessDaemon product.
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("HarnessDaemon"))

        #if DEBUG
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repoRoot.appendingPathComponent(".build/debug/HarnessDaemon"))
        candidates.append(repoRoot.appendingPathComponent(".build/release/HarnessDaemon"))
        #endif

        candidates.append(URL(fileURLWithPath: "/usr/local/bin/HarnessDaemon"))

        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
