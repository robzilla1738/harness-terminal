import Foundation

/// Parses the JSON an agent's notification hook delivers on **stdin** (Claude Code's
/// `Notification` event passes `{ "message": …, "cwd": …, "hook_event_name": …, … }` on
/// stdin — not via an env var), so `harness-cli notify --from-hook` can surface the real
/// message instead of a blank body. Lives in HarnessCore so it's covered by the portable
/// test suite, alongside `JSONMerge` / `OSCNotificationParser`.
public enum HookNotificationParser {
    public struct Parsed: Sendable, Equatable {
        /// The user-facing message (`message` field), if present and non-empty.
        public let message: String?
        /// The agent's working directory (`cwd` field), if present — handy for titles.
        public let cwd: String?

        public init(message: String?, cwd: String?) {
            self.message = message
            self.cwd = cwd
        }
    }

    /// Decode a hook's stdin payload. Returns `nil` for empty or non-object/invalid JSON so
    /// the caller falls back to its flags — never throws and never blocks.
    public static func parse(_ data: Data) -> Parsed? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any]
        else { return nil }
        return Parsed(
            message: nonEmptyString(dict["message"]),
            cwd: nonEmptyString(dict["cwd"])
        )
    }

    /// The body to show: the parsed `message` when present, else the CLI `--body`/`--message`
    /// fallback, else a sensible default. Keeps `harness-cli notify` useful for every agent.
    public static func resolveBody(parsed: Parsed?, fallbackBody: String?) -> String {
        if let message = parsed?.message { return message }
        if let fallback = fallbackBody, !fallback.isEmpty { return fallback }
        return "Needs attention"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
