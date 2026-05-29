import Darwin
import Foundation
import HarnessCore

/// Connects the app to the long-lived `HarnessDaemon` process. The daemon is
/// owned by launchd (installed by `LaunchAgentInstaller`) in release builds so it
/// survives `Harness.app` quitting, logout, and reboot. The launcher's job is to
/// *find* a running daemon and, if none, start one — fast and without freezing the
/// UI.
///
/// **Startup must never block the main thread.** `ensureRunning(then:)` runs the
/// whole discover→spawn→poll dance on a background queue and calls back on the
/// main thread once the daemon answers (or gives up). The strategy is
/// *spawn-first*: if a quick ping fails we immediately spawn the bundled daemon
/// rather than waiting on launchd, because a stale LaunchAgent (e.g. a DerivedData
/// path from a previous Xcode build that no longer exists) would otherwise make us
/// poll for seconds for a daemon that can never come up.
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
        if daemonResponds(timeout: 0.4) { return true }

        // Spawn-first: get a daemon on the socket right now. In release we also
        // (re)install the LaunchAgent so the daemon survives app quit, but we do
        // not *wait* on launchd — the spawned process serves this session.
        spawnFallbackProcess()
        if pollUntilResponding(timeoutSeconds: 3) {
            #if !DEBUG
            _ = installLaunchAgentIfPossible()
            #endif
            return true
        }
        // Last resort: maybe a (valid) LaunchAgent can bring one up.
        #if !DEBUG
        if installLaunchAgentIfPossible(), pollUntilResponding(timeoutSeconds: 2) { return true }
        #endif
        return false
    }

    private func daemonResponds(timeout: TimeInterval = 0.5) -> Bool {
        guard let response = try? DaemonClient().request(.ping, timeout: timeout) else { return false }
        if case .pong = response { return true }
        return false
    }

    private func pollUntilResponding(timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if daemonResponds(timeout: 0.3) { return true }
            usleep(100_000)
        }
        return false
    }

    private func installLaunchAgentIfPossible() -> Bool {
        guard let executable = daemonExecutableURL() else { return false }
        do {
            _ = try LaunchAgentInstaller.install(daemonPath: executable)
            return true
        } catch {
            fputs("Harness: LaunchAgent install failed: \(error) — using in-process daemon\n", stderr)
            return false
        }
    }

    private func spawnFallbackProcess() {
        // Don't stack duplicate spawns if a previous one is still coming up.
        if let existing = fallbackProcess, existing.isRunning { return }
        guard let executable = daemonExecutableURL() else {
            fputs("Harness: could not locate HarnessDaemon executable\n", stderr)
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
            fputs("Harness: failed to spawn HarnessDaemon at \(executable.path): \(error)\n", stderr)
        }
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
