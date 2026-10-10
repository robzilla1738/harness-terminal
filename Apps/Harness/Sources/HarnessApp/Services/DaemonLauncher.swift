import Darwin
import Foundation
import HarnessCore

/// Connects the app to the long-lived `HarnessDaemon` process. The daemon is
/// owned by launchd (installed by `LaunchAgentInstaller`) in release builds so it
/// survives `Harness.app` quitting. Logout or reboot ends live programs; saved
/// layouts can create fresh shells afterward. The launcher's job is to
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
    private let upgradeLock = NSLock()
    private var upgrade: DaemonUpgrade?
    var pendingUpgrade: DaemonUpgrade? {
        upgradeLock.lock(); defer { upgradeLock.unlock() }; return upgrade
    }

    func replaceDaemon(then completion: @escaping @MainActor (String?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let failure: String?
            do {
                switch try DaemonClient().request(.replaceDaemon(executable: self.daemonExecutableURL()?.path), timeout: 30) {
                case .ok:
                    let stats = self.daemonStats()
                    self.setUpgrade(stats.map { $0.updateAvailable ? DaemonUpgrade(stats: $0) : nil } ?? nil)
                    failure = nil
                case let .error(message): failure = message
                default: failure = "Unexpected replacement response; running work is retained."
                }
            } catch { failure = error.localizedDescription }
            Task { @MainActor in completion(failure) }
        }
    }

    private func setUpgrade(_ value: DaemonUpgrade?) {
        upgradeLock.lock(); upgrade = value; upgradeLock.unlock()
    }

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

    func restart(force: Bool, then completion: @escaping @MainActor (String?) -> Void) {
        queue.async { [weak self] in
            let failure: String?
            do {
                _ = try DaemonRestart.stop(force: force)
                #if !DEBUG
                if !HarnessPaths.hasHomeOverride { _ = self?.installLaunchAgentIfPossible(activateChanges: true) }
                #endif
                failure = self?.ensureRunningBlocking() == true ? nil : "The replacement is not ready. Inspect the session-service logs."
            } catch { failure = String(describing: error) }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(failure) } }
        }
    }

    /// Synchronous variant for non-main callers/tests. Never call from the main thread.
    @discardableResult
    func ensureRunningBlocking() -> Bool {
        #if !DEBUG
        var adoptServiceChanges = false
        #endif
        // Refresh only the on-disk candidates. A running daemon retains its executable inode.
        #if !DEBUG
        if !HarnessPaths.hasHomeOverride { refreshInstalledBinaries() }
        #endif
        if let stats = daemonStats(timeout: 0.4) {
            if stats.shutdownPending == true { setUpgrade(DaemonUpgrade(stats: stats)); return false }
            setUpgrade(stats.updateAvailable || stats.compatibility != .compatible
                ? DaemonUpgrade(stats: stats) : nil)
            if stats.daemonUpdateAvailable, stats.daemonAvailable != false, stats.compatibility == .compatible, stats.supports(DaemonStats.sessionHost) {
                if case .ok = try? DaemonClient().request(.replaceDaemon(executable: daemonExecutableURL()?.path), timeout: 30) {
                    if let updated = daemonStats() { setUpgrade(updated.updateAvailable ? DaemonUpgrade(stats: updated) : nil) }
                }
                return true
            }
            // An idle legacy shell still owns environment and background jobs.
            if stats.updateAvailable, stats.compatibility == .compatible,
               stats.mayRestartWithoutInterruption, stats.supports(DaemonStats.guardedRestart) {
                do { _ = try DaemonRestart.stop(force: false) }
                catch { return true } // A concurrent new shell wins over automatic adoption.
                #if !DEBUG
                adoptServiceChanges = true
                #endif
            } else { return stats.compatibility == .compatible }
        } else if daemonResponds(timeout: 0.2) {
            setUpgrade(DaemonUpgrade(stats: nil))
            return false
        }

        switch DaemonOwnership.probe() {
        case .alive, .uncertain:
            setUpgrade(DaemonUpgrade(stats: nil))
            return false
        case .absent: break
        }

        // In release, install the corrected LaunchAgent before falling back. This
        // fixes stale DerivedData/App bundle paths and avoids running a fallback
        // daemon underneath a launchd service that then retries every throttle
        // interval.
        #if !DEBUG
        if !HarnessPaths.hasHomeOverride, installLaunchAgentIfPossible(activateChanges: adoptServiceChanges), pollUntilResponding(timeoutSeconds: 4) { return true }
        #endif

        // A service may be slow to start. Recheck ownership before considering a fallback.
        if case .alive = DaemonOwnership.probe() { return false }
        if case .uncertain = DaemonOwnership.probe() { return false }
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

    private func pollUntilResponding(timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let stats = daemonStats(timeout: 0.3) {
                setUpgrade(stats.updateAvailable || stats.compatibility != .compatible
                    ? DaemonUpgrade(stats: stats) : nil)
                return stats.compatibility == .compatible
            }
            if daemonResponds(timeout: 0.2) { setUpgrade(DaemonUpgrade(stats: nil)); return false }
            // Thread.sleep is preferred over usleep here: both park the calling thread for
            // 100 ms, but Thread.sleep carries clearer intent and integrates better with the
            // Swift runtime's thread accounting. These polls run exclusively on `queue` — a
            // private serial DispatchQueue — so blocking its one worker thread for up to ~4 s
            // is intentional and bounded; no other work is queued behind them.
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func installLaunchAgentIfPossible(activateChanges: Bool = false) -> Bool {
        guard let executable = launchAgentDaemonTarget() else { return false }
        do {
            _ = try LaunchAgentInstaller.install(daemonPath: executable, activateChanges: activateChanges)
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
    /// refresh is independent of whether the running daemon can be replaced.
    private func refreshInstalledBinaries() {
        let owner = bundledBinaryURL(named: "HarnessSessionHost")
        if let owner, FileManager.default.fileExists(atPath: BinaryRefresher.installedDaemonPath.path) {
            try? BinaryRefresher.copyExecutable(from: owner, to: BinaryRefresher.installedSessionHostPath)
        }
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
