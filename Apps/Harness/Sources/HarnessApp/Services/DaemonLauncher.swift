import Darwin
import Foundation
import HarnessCore

/// Connects the app to the long-lived `HarnessDaemon` process. The daemon is
/// owned by launchd (installed by `LaunchAgentInstaller`) so it survives
/// `Harness.app` quitting, system logout, and even a fresh boot. The launcher's
/// job is to *find* a running daemon and, on first run only, install the
/// LaunchAgent so that one exists.
///
/// Direct child-process spawning is a last-resort fallback for DEBUG / preview
/// builds where the LaunchAgent isn't installed; the app never kills a running
/// daemon on quit.
///
/// @unchecked Sendable: launch/poll state is confined to the serial `queue`.
final class DaemonLauncher: @unchecked Sendable {
    static let shared = DaemonLauncher()

    private var fallbackProcess: Process?
    private let queue = DispatchQueue(label: "com.robert.harness.daemon-launcher")

    private init() {}

    func ensureRunning() {
        queue.sync {
            if daemonResponds() { return }
            // Try to install the LaunchAgent (idempotent). If installed, launchd
            // will start the daemon on the next request to the socket.
            if installLaunchAgentIfPossible() {
                if pollUntilResponding(timeoutSeconds: 3) { return }
            }
            spawnFallbackProcess()
        }
    }

    private func daemonResponds() -> Bool {
        guard let response = try? DaemonClient().request(.ping, timeout: 0.5) else { return false }
        if case .pong = response { return true }
        return false
    }

    private func pollUntilResponding(timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if daemonResponds() { return true }
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
            fputs("Harness: LaunchAgent install failed: \(error) — falling back to in-process daemon\n", stderr)
            return false
        }
    }

    private func spawnFallbackProcess() {
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
        try? proc.run()
        fallbackProcess = proc
        _ = pollUntilResponding(timeoutSeconds: 3)
    }

    private func daemonExecutableURL() -> URL? {
        if let executable = Bundle.main.executableURL {
            let bundled = executable.deletingLastPathComponent().appendingPathComponent("HarnessDaemon")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }
        #if DEBUG
        let buildDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/HarnessDaemon")
        if FileManager.default.fileExists(atPath: buildDir.path) {
            return buildDir
        }
        #endif
        if let bundle = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent() as URL? {
            let candidate = bundle.appendingPathComponent("MacOS/HarnessDaemon")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return URL(fileURLWithPath: "/usr/local/bin/HarnessDaemon")
    }
}
