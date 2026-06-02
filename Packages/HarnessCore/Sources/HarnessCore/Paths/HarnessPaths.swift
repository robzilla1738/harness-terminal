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
        #if os(Linux)
        // Headless/Linux daemon: follow the XDG base-dir spec rather than ~/Library.
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("harness", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/harness", isDirectory: true)
        #else
        // Fall back to ~/Library/Application Support if the lookup ever returns empty
        // (it shouldn't on macOS) rather than force-unwrapping and crashing at launch.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Harness", isDirectory: true)
        #endif
    }

    /// Directory the control socket lives in. On Darwin this is the application-support root, so the
    /// socket path is unchanged. On Linux a short `$XDG_RUNTIME_DIR` is preferred when available so
    /// the path comfortably fits `sockaddr_un.sun_path` (a deep `~/.local/share` could overflow it).
    /// A `HARNESS_HOME` override always wins, so tests keep the socket inside their temp root.
    public static var runtimeDirectory: URL {
        #if os(Linux)
        if overrideRoot == nil,
           let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !xdg.isEmpty
        {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("harness", isDirectory: true)
        }
        #endif
        return applicationSupport
    }

    public static var sessionsDirectory: URL {
        applicationSupport.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Per-surface persisted scrollback lives here (one `<surfaceID>.scroll` file each).
    /// Kept under `sessions/` so it ships in the same owner-only (0o700) tree as the layout.
    public static var scrollbackDirectory: URL {
        sessionsDirectory.appendingPathComponent("scrollback", isDirectory: true)
    }

    /// The persisted-scrollback file for a surface. Surface IDs are UUID strings, so they're
    /// safe as a path component; the `.scroll` extension namespaces them within the directory.
    public static func scrollbackFileURL(forSurfaceID surfaceID: String) -> URL {
        scrollbackDirectory.appendingPathComponent("\(surfaceID).scroll")
    }

    public static var socketURL: URL {
        runtimeDirectory.appendingPathComponent("harness.sock")
    }

    /// Max bytes for a Unix-domain `sockaddr_un.sun_path` (including the trailing NUL): 104 on
    /// Darwin, 108 on Linux. A path at or over this silently truncates, making `connect`/`bind`
    /// target the wrong socket — so callers validate against it instead.
    #if os(Linux)
    public static let maxSocketPathLength = 108
    #else
    public static let maxSocketPathLength = 104
    #endif

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

    /// Saved remote-host configs for the GUI/CLI to connect to daemons on other machines.
    public static var remoteHostsURL: URL {
        sessionsDirectory.appendingPathComponent("remote-hosts.json")
    }

    /// Local sockets that SSH forwards to remote daemons (one per connected host). Kept short and
    /// under the runtime dir so the forwarded path comfortably fits `sockaddr_un.sun_path`.
    public static var tunnelsDirectory: URL {
        runtimeDirectory.appendingPathComponent("tunnels", isDirectory: true)
    }

    public static func tunnelSocketURL(forHost name: String) -> URL {
        // A readable, filesystem-safe prefix (bounded so `sun_path` doesn't overflow) disambiguated
        // by a deterministic hash of the *full* name — so distinct hosts that sanitize to the same
        // text (e.g. "dev.box" vs "dev-box") never share a socket path and clobber each other.
        let safe = String(
            name.unicodeScalars
                .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
                .prefix(32))
        return tunnelsDirectory.appendingPathComponent("\(safe)-\(fnv1aHex(name)).sock")
    }

    /// Deterministic 32-bit FNV-1a hash as 8 hex chars. `Hasher` is per-process seeded, so it can't
    /// produce a stable on-disk name across daemon runs; this can.
    private static func fnv1aHex(_ string: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return String(format: "%08x", hash)
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
            at: scrollbackDirectory, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.createDirectory(
            at: logsDirectory, withIntermediateDirectories: true, attributes: ownerOnly)
        // On Linux the control socket may live under a separate `$XDG_RUNTIME_DIR`; make sure it
        // exists (owner-only) too. On Darwin this is the same path as the root, so it's a no-op.
        if runtimeDirectory.path != applicationSupport.path {
            try FileManager.default.createDirectory(
                at: runtimeDirectory, withIntermediateDirectories: true, attributes: ownerOnly)
        }
        // createDirectory only applies attributes to directories it creates; tighten an
        // existing root that an older build made with the default 0o755 umask.
        try? FileManager.default.setAttributes(ownerOnly, ofItemAtPath: applicationSupport.path)
    }

    // MARK: - Config-file persistence helpers
    //
    // Every JSON store (layout / options / hooks / keybindings / settings / environment) shares two
    // needs: preserve an unreadable file instead of overwriting it, and never silently swallow a
    // save failure. These were copy-pasted per store — with a subtle bug: the "backed up" message
    // printed unconditionally, even when the move failed — so they live here once.

    /// Move an unreadable config file aside to `<name>.corrupt` so the caller can recover it instead
    /// of overwriting it with defaults. Replaces any stale backup. Logs to stderr under `label` —
    /// naming the backup on success, the error on failure — and returns whether the file was
    /// actually moved, so a failed backup is never reported as a success.
    @discardableResult
    public static func backupCorruptFile(at url: URL, label: String) -> Bool {
        let backup = url.appendingPathExtension("corrupt")
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.moveItem(at: url, to: backup)
            fputs("\(label): \(url.lastPathComponent) unreadable — backed up to \(backup.lastPathComponent)\n", harnessStderr)
            return true
        } catch {
            fputs("\(label): \(url.lastPathComponent) unreadable and could not be backed up: \(error)\n", harnessStderr)
            return false
        }
    }

    /// Atomically write `data` to `url` (temp + rename, never a partial file), logging a failure to
    /// stderr under `label` instead of swallowing it. Returns success. For fire-and-forget saves
    /// with no caller to propagate a throw to; stores that surface write errors keep their `try`.
    @discardableResult
    public static func atomicWrite(_ data: Data, to url: URL, label: String) -> Bool {
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            fputs("\(label): failed to write \(url.lastPathComponent): \(error)\n", harnessStderr)
            return false
        }
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
