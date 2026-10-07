import Foundation

/// Where a GUI process finds `harness-cli` without linking Lua.
public enum HarnessCLILocator {
    public static func url(
        bundleExecutable: URL? = Bundle.main.executableURL,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        var candidates: [URL] = []
        if let bundleExecutable {
            candidates.append(bundleExecutable.deletingLastPathComponent().appendingPathComponent("harness-cli"))
        }
        candidates.append(HarnessPaths.applicationSupport.appendingPathComponent("bin").appendingPathComponent("harness-cli"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/harness-cli"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/harness-cli"))
        return candidates.first { isExecutable($0.path) }
    }
}

/// What a Lua action run from the app produced.
public struct ScriptActionResult: Equatable, Sendable {
    /// The action's last error line, when it exited non-zero.
    public var failure: String?
    /// Commands the action queued with `harness.queue`, for the app to run in order.
    public var queued: [String]

    public init(failure: String?, queued: [String]) {
        self.failure = failure
        self.queued = queued
    }
}

public enum ScriptActionRunner {
    public static func actionArguments(name: String, origin: ScriptOrigin) -> [String] {
        ["do", "--action", name, "--origin", origin.rawValue]
    }

    public static func reloadArguments(file: String) -> [String] {
        ["config", "reload", "--file", file]
    }

    /// Later of the config file and the published manifest. A config edit moves the stamp.
    public static func stamp() -> Date? {
        let config = modificationDate(URL(fileURLWithPath: ScriptConfigPath.resolve()))
        let stored = modificationDate(ScriptStore.url)
        switch (config, stored) {
        case let (config?, stored?): return max(config, stored)
        case let (config?, nil): return config
        case let (nil, stored?): return stored
        case (nil, nil): return nil
        }
    }

    /// Publish `script.json` when `init.lua` is newer. No file watcher: this runs when the palette
    /// or a key needs the map. A missing CLI or a missing config file leaves the last manifest.
    /// Blocks on a `harness-cli` process; the typing path uses `syncManifestInBackground`.
    public static func syncManifest() {
        let config = ScriptConfigPath.resolve()
        let configURL = URL(fileURLWithPath: config)
        guard let configDate = modificationDate(configURL) else { return }
        if let stored = modificationDate(ScriptStore.url), stored >= configDate { return }
        guard let cli = url() else { return }
        let process = Process()
        process.executableURL = cli
        process.arguments = reloadArguments(file: config)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// `syncManifest` off the caller's thread. Overlapping requests collapse into the one in flight;
    /// the next stamp check picks up the published manifest.
    public static func syncManifestInBackground() {
        guard syncGate.begin() else { return }
        DispatchQueue.global(qos: .utility).async {
            syncManifest()
            syncGate.end()
        }
    }

    /// Runs the action in `harness-cli do` off the caller's thread, then reports what happened
    /// on an arbitrary queue: the failure line if it exited non-zero, and the commands it
    /// queued with `harness.queue` (one per stdout line) for the app to run.
    public static func run(
        name: String,
        origin: ScriptOrigin,
        surface: String? = nil,
        finished: (@Sendable (ScriptActionResult) -> Void)? = nil
    ) {
        guard let cli = url() else {
            finished?(ScriptActionResult(failure: "harness-cli not found; action \(name) did not run", queued: []))
            return
        }
        var environment = ProcessInfo.processInfo.environment
        environment["HARNESS_ORIGIN"] = origin.rawValue
        if let surface, !surface.isEmpty {
            environment["HARNESS_SURFACE"] = surface
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: ScriptActionResult
            do {
                let output = try ProcessCapture.run(cli, arguments: actionArguments(name: name, origin: origin), environment: environment)
                result = ScriptActionResult(
                    failure: output.status == 0 ? nil : failureMessage(name: name, status: output.status, stderr: output.stderr),
                    queued: queuedCommands(output.stdout)
                )
            } catch {
                result = ScriptActionResult(failure: "action \(name): \(error.localizedDescription)", queued: [])
            }
            finished?(result)
        }
    }

    /// `harness.queue` output: one command per non-empty stdout line.
    public static func queuedCommands(_ stdout: Data) -> [String] {
        String(decoding: stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Last non-empty stderr line, or the exit status when the action printed nothing.
    public static func failureMessage(name: String, status: Int32, stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return "action \(name) failed (exit \(status))" }
        return "action \(name): \(line.trimmingCharacters(in: .whitespaces))"
    }

    private static let syncGate = InFlightGate()

    private static func url() -> URL? { HarnessCLILocator.url() }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// One-at-a-time flag shared across threads.
private final class InFlightGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    func end() {
        lock.lock(); running = false; lock.unlock()
    }
}
