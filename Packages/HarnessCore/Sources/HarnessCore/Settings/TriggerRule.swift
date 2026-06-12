import Foundation

/// One output trigger: a pattern matched against each terminal line as it completes (the
/// cursor moves past it), firing an action — `highlight` shades the matched span in the
/// scrollback, `notify` posts a notification (per-rule cooldown applies). Configured as an
/// array under `"triggers"` in settings.json; reload-on-save applies changes live:
///
/// ```json
/// "triggers": [
///   {"pattern": "ERROR", "action": "highlight"},
///   {"pattern": "^Build failed", "match": "regex", "action": "notify"}
/// ]
/// ```
///
/// Decoding is tolerant per field (unknown `match`/`action` strings fall back to the
/// defaults; a missing pattern decodes empty and the rule is ignored) so a hand-edited rule
/// can never corrupt-backup the whole settings file.
public struct TriggerRule: Codable, Equatable, Sendable {
    public enum Match: String, Codable, Sendable { case literal, regex }
    public enum Action: String, Codable, Sendable { case notify, highlight }

    public var pattern: String
    public var match: Match
    public var action: Action
    /// Kept in config so a rule can be parked without deleting it.
    public var enabled: Bool

    public init(
        pattern: String, match: Match = .literal, action: Action = .highlight, enabled: Bool = true
    ) {
        self.pattern = pattern
        self.match = match
        self.action = action
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case pattern, match, action, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? ""
        match = (try? c.decodeIfPresent(String.self, forKey: .match))
            .flatMap { $0 }.flatMap(Match.init(rawValue:)) ?? .literal
        action = (try? c.decodeIfPresent(String.self, forKey: .action))
            .flatMap { $0 }.flatMap(Action.init(rawValue:)) ?? .highlight
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)).flatMap { $0 } ?? true
    }
}
