#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// One per-host/per-command profile: while a pane's reported hostname (OSC 7) or foreground
/// process matches, that pane's terminal canvas renders with `theme` instead of the global
/// theme — e.g. a red-tinted theme over ssh to production. Configured as a `"profiles"`
/// array in settings.json (first matching rule wins; saved changes apply live):
///
/// ```json
/// "profiles": [
///   {"host": "*.prod.example.com", "theme": "Red Alert"},
///   {"command": "ssh", "theme": "Dracula"}
/// ]
/// ```
///
/// The override is a render-time layer per surface — it is never written back to settings,
/// so a profile can't corrupt the persisted theme (the audit roadmap's sanctioned design).
/// Decoding is tolerant per field, like `TriggerRule`.
public struct ProfileRule: Codable, Equatable, Sendable {
    /// Glob matched (case-insensitively) against the pane's OSC 7 hostname. Reliable host
    /// switching needs shell integration on both ends (the local shell's OSC 7 is what
    /// reverts the override after `ssh` exits).
    public var host: String?
    /// Glob matched (case-insensitively) against the pane's foreground process name.
    public var command: String?
    /// Theme applied while matched (canvas only — window chrome keeps the global theme).
    public var theme: String
    public var enabled: Bool

    public init(host: String? = nil, command: String? = nil, theme: String, enabled: Bool = true) {
        self.host = host
        self.command = command
        self.theme = theme
        self.enabled = enabled
    }

    /// Whether this rule matches the pane's current vantage. A rule with no criteria never
    /// matches (it would silently re-theme everything); set criteria must ALL hold.
    public func matches(host activeHost: String?, command activeCommand: String?) -> Bool {
        guard enabled, !theme.isEmpty, host != nil || command != nil else { return false }
        if let host {
            guard let activeHost, Self.glob(host, matches: activeHost) else { return false }
        }
        if let command {
            guard let activeCommand, Self.glob(command, matches: activeCommand) else { return false }
        }
        return true
    }

    /// POSIX `fnmatch` glob, case-folded on both sides (FNM_CASEFOLD is a GNU/BSD extension,
    /// so fold manually for Linux parity).
    static func glob(_ pattern: String, matches value: String) -> Bool {
        fnmatch(pattern.lowercased(), value.lowercased(), 0) == 0
    }

    private enum CodingKeys: String, CodingKey { case host, command, theme, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = (try? c.decodeIfPresent(String.self, forKey: .host)).flatMap { $0 }
        command = (try? c.decodeIfPresent(String.self, forKey: .command)).flatMap { $0 }
        theme = (try? c.decodeIfPresent(String.self, forKey: .theme)).flatMap { $0 } ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? true
    }
}
