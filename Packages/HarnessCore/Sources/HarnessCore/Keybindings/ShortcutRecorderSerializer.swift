import Foundation

/// The dash-joined chord format shared by the prefix key, the quick-terminal hotkey and palette
/// shortcuts: `ctrl-a`, `shift-cmd-p`, `cmd--`, `opt-up`, `f5`. Keys are a lowercased character
/// or one of `namedKeys`; `serialize`, `parse` and `glyphString` round-trip.
public enum ShortcutRecorderSerializer {
    /// Serialize a recorded keystroke. Pass `keyCode` when there is one: named keys (arrows,
    /// space, F-keys…) are recognized from it, independent of the characters the event carries.
    public static func serialize(keyCode: UInt16? = nil, raw: String?, modifiers: KeySpec.Modifiers) -> String? {
        let key: String
        if let keyCode, let named = namedKey(forKeyCode: keyCode) {
            key = named
        } else {
            guard let raw, !raw.isEmpty else { return nil }
            key = keyName(forCharacters: ControlKeyNormalizer.normalizedKey(
                from: raw,
                controlPressed: modifiers.contains(.control)
            ))
        }
        return format(KeySpec(key: key, modifiers: modifiers))
    }

    public static func format(_ spec: KeySpec) -> String {
        var parts: [String] = []
        if spec.modifiers.contains(.control) { parts.append("ctrl") }
        if spec.modifiers.contains(.option) { parts.append("opt") }
        if spec.modifiers.contains(.shift) { parts.append("shift") }
        if spec.modifiers.contains(.command) { parts.append("cmd") }
        parts.append(spec.key)
        return parts.joined(separator: "-")
    }

    /// Parse a chord into its modifiers and canonical key (`up`, `space`, `f5`, `-`, `a`).
    /// A trailing `--` is the minus key. Unknown modifiers or multi-character keys fail.
    public static func parse(_ raw: String) -> KeySpec? {
        var body = Substring(raw.lowercased())
        let keyToken: String
        if body.hasSuffix("-") {
            keyToken = "-"
            body = body.dropLast()
            if body.hasSuffix("-") { body = body.dropLast() } else if !body.isEmpty { return nil }
        } else if let dash = body.lastIndex(of: "-") {
            keyToken = String(body[body.index(after: dash)...])
            body = body[..<dash]
        } else {
            keyToken = String(body)
            body = ""
        }
        var modifiers: KeySpec.Modifiers = []
        if !body.isEmpty {
            for component in body.split(separator: "-", omittingEmptySubsequences: false) {
                switch component {
                case "ctrl", "control": modifiers.insert(.control)
                case "cmd", "command": modifiers.insert(.command)
                case "opt", "alt", "option": modifiers.insert(.option)
                case "shift": modifiers.insert(.shift)
                default: return nil
                }
            }
        }
        guard let key = canonicalKey(keyToken) else { return nil }
        return KeySpec(key: key, modifiers: modifiers)
    }

    /// A key token in canonical form: aliases resolved (`return` → `enter`), single characters
    /// mapped through `keyName(forCharacters:)`. Nil for an unknown multi-character name.
    public static func canonicalKey(_ token: String) -> String? {
        let lower = token.lowercased()
        if let alias = aliases[lower] { return alias }
        if namedKeys.contains(lower) { return lower }
        guard lower.count == 1 else { return nil }
        return keyName(forCharacters: lower)
    }

    public static func isNamedKey(_ key: String) -> Bool { namedKeys.contains(key) }

    /// The canonical name for a key's characters (`\u{F700}` → `up`, `" "` → `space`), or the
    /// lowercased characters for an ordinary key.
    public static func keyName(forCharacters raw: String) -> String {
        guard raw.count == 1, let scalar = raw.unicodeScalars.first else { return raw.lowercased() }
        switch scalar.value {
        case 0x1B: return "escape"
        case 0x09, 0x19: return "tab"
        case 0x0D, 0x03: return "enter"
        case 0x7F, 0x08: return "backspace"
        case 0x20: return "space"
        case 0xF700: return "up"
        case 0xF701: return "down"
        case 0xF702: return "left"
        case 0xF703: return "right"
        case 0xF728: return "forwarddelete"
        case 0xF729: return "home"
        case 0xF72B: return "end"
        case 0xF72C: return "pageup"
        case 0xF72D: return "pagedown"
        case 0xF704...0xF717: return "f\(Int(scalar.value) - 0xF703)"
        default: return raw.lowercased()
        }
    }

    /// The canonical name of a named key from its macOS virtual key code (layout-independent).
    public static func namedKey(forKeyCode keyCode: UInt16) -> String? {
        keyCodeNames[keyCode]
    }

    public static func glyphString(for raw: String) -> String {
        parse(raw).map(glyphString(for:)) ?? raw
    }

    /// `⌃⌥⇧⌘` then the key: a capital letter, an arrow/return/tab glyph, or `F5` / `Space`.
    public static func glyphString(for spec: KeySpec) -> String {
        var glyphs = ""
        if spec.modifiers.contains(.control) { glyphs += "⌃" }
        if spec.modifiers.contains(.option) { glyphs += "⌥" }
        if spec.modifiers.contains(.shift) { glyphs += "⇧" }
        if spec.modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + (keyGlyphs[spec.key] ?? spec.key.uppercased())
    }

    private static let aliases: [String: String] = [
        "return": "enter", "esc": "escape", "delete": "backspace", "grave": "`",
    ]

    /// Carbon `kVK_*` codes; these are hardware constants, stable across layouts.
    private static let keyCodeNames: [UInt16: String] = [
        53: "escape", 48: "tab", 36: "enter", 76: "enter", 49: "space",
        51: "backspace", 117: "forwarddelete",
        126: "up", 125: "down", 123: "left", 124: "right",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8",
        101: "f9", 109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15",
        106: "f16", 64: "f17", 79: "f18", 80: "f19", 90: "f20",
    ]

    private static let namedKeys = Set(keyCodeNames.values)

    private static let keyGlyphs: [String: String] = [
        "escape": "⎋", "tab": "⇥", "enter": "↩", "space": "Space",
        "backspace": "⌫", "forwarddelete": "⌦",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]
}
