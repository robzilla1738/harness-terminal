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

    public static func run(name: String, origin: ScriptOrigin, surface: String? = nil) {
        guard let cli = url() else { return }
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
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func url() -> URL? { HarnessCLILocator.url() }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
