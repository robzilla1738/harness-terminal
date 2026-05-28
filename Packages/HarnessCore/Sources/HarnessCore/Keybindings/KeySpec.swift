import Foundation

/// Platform-independent description of a single keystroke: a base key + a set
/// of modifiers. Round-trippable to/from textual form (`C-a`, `M-1`, `S-Tab`,
/// `Up`) and matched against a raw event on macOS (and, in the future, on a
/// remote attach client).
///
/// The textual form is the one users see in `keybindings.json`, the `:` prompt
/// (`bind-key C-a d detach-client`), and the cheatsheet, so it must stay
/// stable.
public struct KeySpec: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let option  = Modifiers(rawValue: 1 << 1) // alt / meta
        public static let shift   = Modifiers(rawValue: 1 << 2)
        public static let command = Modifiers(rawValue: 1 << 3)
    }

    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public var description: String { Self.format(self) }

    /// Parse `C-a`, `M-1`, `S-Tab`, `Up`, `?`, `"`, `c`, etc. Case-insensitive
    /// for the modifier prefixes; the base key is preserved verbatim so users
    /// can bind upper-case letters when they want to.
    public static func parse(_ raw: String) -> KeySpec? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var modifiers = Modifiers()
        var rest = trimmed
        while let dashIndex = rest.firstIndex(of: "-") {
            let prefix = rest[..<dashIndex].lowercased()
            // A literal `-` as the base key (e.g. binding `-` itself) is allowed
            // when nothing else precedes the dash. Detect that here.
            guard !prefix.isEmpty else { break }
            switch prefix {
            case "c", "ctrl", "control": modifiers.insert(.control)
            case "m", "meta", "opt", "option", "alt": modifiers.insert(.option)
            case "s", "shift": modifiers.insert(.shift)
            case "cmd", "command", "super": modifiers.insert(.command)
            default: return nil
            }
            rest = String(rest[rest.index(after: dashIndex)...])
            if rest.isEmpty { return nil }
        }
        return KeySpec(key: rest, modifiers: modifiers)
    }

    public static func format(_ spec: KeySpec) -> String {
        var prefix = ""
        if spec.modifiers.contains(.control) { prefix += "C-" }
        if spec.modifiers.contains(.option)  { prefix += "M-" }
        if spec.modifiers.contains(.shift)   { prefix += "S-" }
        if spec.modifiers.contains(.command) { prefix += "Cmd-" }
        return prefix + spec.key
    }

    // MARK: Codable as a string

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = KeySpec.parse(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid KeySpec: \(raw)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
