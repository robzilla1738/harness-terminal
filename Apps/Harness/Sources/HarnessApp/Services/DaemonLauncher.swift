import Foundation
import HarnessCore

final class DaemonLauncher: @unchecked Sendable {
    static let shared = DaemonLauncher()

    private var process: Process?
    private let queue = DispatchQueue(label: "com.robert.harness.daemon-launcher")

    private init() {}

    func ensureRunning() {
        queue.sync {
            if daemonResponds() { return }
            launchDaemon()
        }
    }

    func stopIfNeeded() {
        queue.sync {
            process?.terminate()
            process = nil
            if FileManager.default.fileExists(atPath: HarnessPaths.socketURL.path) {
                try? FileManager.default.removeItem(at: HarnessPaths.socketURL)
            }
        }
    }

    private func daemonResponds() -> Bool {
        guard let response = try? DaemonClient().request(.ping, timeout: 0.5) else { return false }
        if case .pong = response { return true }
        return false
    }

    private func launchDaemon() {
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
        process = proc
        for _ in 0 ..< 30 {
            if daemonResponds() { return }
            usleep(100_000)
        }
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
