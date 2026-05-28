import Foundation

public enum HarnessPaths {
    private static var overrideRoot: URL? {
        guard let raw = ProcessInfo.processInfo.environment["HARNESS_HOME"], !raw.isEmpty else {
            if let bundled = Bundle.main.object(forInfoDictionaryKey: "HarnessPreviewHome") as? String,
               !bundled.isEmpty
            {
                return URL(fileURLWithPath: (bundled as NSString).expandingTildeInPath, isDirectory: true)
            }
            return nil
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    public static var applicationSupport: URL {
        if let overrideRoot { return overrideRoot }
        // Fall back to ~/Library/Application Support if the lookup ever returns empty
        // (it shouldn't on macOS) rather than force-unwrapping and crashing at launch.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Harness", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        applicationSupport.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var socketURL: URL {
        applicationSupport.appendingPathComponent("harness.sock")
    }

    public static var snapshotURL: URL {
        sessionsDirectory.appendingPathComponent("layout.json")
    }

    public static var settingsURL: URL {
        applicationSupport.appendingPathComponent("settings.json")
    }

    public static var logsDirectory: URL {
        applicationSupport.appendingPathComponent("logs", isDirectory: true)
    }

    public static var daemonLogURL: URL {
        logsDirectory.appendingPathComponent("daemon.log")
    }

    public static var daemonPIDURL: URL {
        applicationSupport.appendingPathComponent("daemon.pid")
    }

    public static var buffersURL: URL {
        applicationSupport.appendingPathComponent("buffers.json")
    }

    public static var fishCompletionDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/fish/completions", isDirectory: true)
    }

    public static var fishCompletionURL: URL {
        fishCompletionDirectory.appendingPathComponent("harness-cli.fish")
    }

    /// launchd label for the user-domain LaunchAgent that supervises HarnessDaemon.
    /// Stable so `launchctl print gui/$UID/<label>` works for support diagnostics.
    public static let launchAgentLabel = "com.robert.harness.daemon"

    public static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist")
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
