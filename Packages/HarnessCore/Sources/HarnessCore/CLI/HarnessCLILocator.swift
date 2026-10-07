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

    /// Runs the action in `harness-cli do` off the caller's thread. `failed` gets the action's
    /// error text (or its exit status) when the process exits non-zero, on an arbitrary queue.
    public static func run(
        name: String,
        origin: ScriptOrigin,
        surface: String? = nil,
        failed: (@Sendable (String) -> Void)? = nil
    ) {
        guard let cli = url() else {
            failed?("harness-cli not found; action \(name) did not run")
            return
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = actionArguments(name: name, origin: origin)
        var environment = ProcessInfo.processInfo.environment
        environment["HARNESS_ORIGIN"] = origin.rawValue
        if let surface, !surface.isEmpty {
            environment["HARNESS_SURFACE"] = surface
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
            } catch {
                failed?("action \(name): \(error.localizedDescription)")
                return
            }
            // Drain before waiting: a full pipe would block the child forever.
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return }
            failed?(failureMessage(name: name, status: process.terminationStatus, stderr: data))
        }
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
