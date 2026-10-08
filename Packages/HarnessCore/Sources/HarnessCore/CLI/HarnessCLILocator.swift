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

/// What the app asks `harness-cli do` to run: a Lua action, or the Lua function bound to a key.
public enum ScriptRequest: Equatable, Sendable {
    case action(String)
    case binding(String)

    var label: String {
        switch self {
        case let .action(name): return "action \(name)"
        case let .binding(spec): return "binding \(spec)"
        }
    }
}

public enum ScriptActionRunner {
    public static func arguments(_ request: ScriptRequest, origin: ScriptOrigin) -> [String] {
        switch request {
        case let .action(name): return ["do", "--action", name, "--origin", origin.rawValue]
        case let .binding(spec): return ["do", "--binding", spec, "--origin", origin.rawValue]
        }
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

    /// Runs the request in `harness-cli do` off the caller's thread, then reports what happened
    /// on an arbitrary queue: the failure line if it exited non-zero, and the commands it
    /// queued with `harness.queue` (one per stdout line) for the app to run. A function
    /// binding pays one process launch per press; that is the price of no Lua in the app.
    public static func run(
        _ request: ScriptRequest,
        origin: ScriptOrigin,
        surface: String? = nil,
        finished: (@Sendable (ScriptActionResult) -> Void)? = nil
    ) {
        let name = request.label
        guard let cli = url() else {
            finished?(ScriptActionResult(failure: "harness-cli not found; \(name) did not run", queued: []))
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
                let output = try ProcessCapture.run(cli, arguments: arguments(request, origin: origin), environment: environment)
                result = ScriptActionResult(
                    failure: output.status == 0 ? nil : failureMessage(name: name, status: output.status, stderr: output.stderr),
                    queued: queuedCommands(output.stdout)
                )
            } catch {
                result = ScriptActionResult(failure: "\(name): \(error.localizedDescription)", queued: [])
            }
            finished?(result)
        }
    }

    /// `harness.queue` output: one command per non-empty stdout line.
    /// `harness.queue` commands from the action's stdout. Each is one marked line (a record
    /// separator, then the command as a JSON string), so a script's own `print` output is never
    /// run as a command and a command may contain a newline.
    public static func queuedCommands(_ stdout: Data) -> [String] {
        String(decoding: stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard line.first == queueMarker,
                      let command = try? JSONDecoder().decode(String.self, from: Data(line.dropFirst().utf8))
                else { return nil }
                let trimmed = command.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
    }

    /// The stdout line `queuedCommands` reads back.
    public static func queuedLine(_ command: String) -> String {
        let json = (try? JSONEncoder().encode(command)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        return String(queueMarker) + json
    }

    private static let queueMarker: Character = "\u{1e}"

    /// Last non-empty stderr line, or the exit status when the action printed nothing.
    /// `name` is the request's label (`action build`).
    public static func failureMessage(name: String, status: Int32, stderr: Data) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        let line = text.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line else { return "\(name) failed (exit \(status))" }
        return "\(name): \(line.trimmingCharacters(in: .whitespaces))"
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
