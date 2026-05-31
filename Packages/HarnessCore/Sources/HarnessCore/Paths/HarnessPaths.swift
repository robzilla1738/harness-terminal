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

    /// Max bytes for a Unix-domain `sockaddr_un.sun_path` on Darwin (104, including the trailing
    /// NUL). A path at or over this silently truncates in `strncpy`, making `connect`/`bind` target
    /// the wrong socket — so callers validate against it instead.
    public static let maxSocketPathLength = 104

    /// The control-socket filesystem path, validated to fit `sun_path`. Throws when `HARNESS_HOME`
    /// (or a deep app-support root) pushes it past the limit, so the daemon/client fail with a
    /// clear message rather than a truncated-path connect/bind that silently misbehaves.
    public static func validatedSocketPath() throws -> String {
        let path = socketURL.path
        guard path.utf8.count < maxSocketPathLength else {
            throw HarnessPathsError.socketPathTooLong(path: path, limit: maxSocketPathLength)
        }
        return path
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
        // The Harness home holds the control socket, session layout, hooks (which run shell
        // commands) and logs — owner-only (0o700) so another local user can't read or tamper
        // with it. Apply on the root and propagate to the subdirectories we own.
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(
            at: applicationSupport, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.createDirectory(
            at: sessionsDirectory, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.createDirectory(
            at: logsDirectory, withIntermediateDirectories: true, attributes: ownerOnly)
        // createDirectory only applies attributes to directories it creates; tighten an
        // existing root that an older build made with the default 0o755 umask.
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: applicationSupport.path)
    }
}

/// Errors from path validation that need to fail loudly rather than degrade silently.
public enum HarnessPathsError: Error, CustomStringConvertible {
    /// The control-socket path is too long for `sockaddr_un.sun_path` (usually a deep
    /// `HARNESS_HOME`). Carries the offending path and the limit for a clear message.
    case socketPathTooLong(path: String, limit: Int)

    public var description: String {
        switch self {
        case let .socketPathTooLong(path, limit):
            return "Harness control-socket path is \(path.utf8.count) bytes (max \(limit - 1)); "
                + "shorten HARNESS_HOME. Path: \(path)"
        }
    }
}
