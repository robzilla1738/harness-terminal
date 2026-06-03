import Foundation

public enum ShortcutRecorderSerializer {
    public static func serialize(raw: String?, modifiers: KeySpec.Modifiers) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let normalizedRaw = ControlKeyNormalizer.normalizedKey(
            from: raw,
            controlPressed: modifiers.contains(.control)
        )
        let key = serializedKey(from: normalizedRaw)
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "-")
    }

    public static func glyphString(for raw: String) -> String {
        let parts = raw.lowercased().split(separator: "-").map(String.init)
        guard let last = parts.last else { return raw }
        var glyphs = ""
        for component in parts.dropLast() {
            switch component {
            case "ctrl", "control": glyphs += "⌃"
            case "opt", "alt", "option": glyphs += "⌥"
            case "shift": glyphs += "⇧"
            case "cmd", "command": glyphs += "⌘"
            default: break
            }
        }
        return glyphs + last.uppercased()
    }

    private static func serializedKey(from raw: String) -> String {
        if raw.count == 1, let scalar = raw.unicodeScalars.first {
            switch scalar.value {
            case 0x1B: return "escape"
            case 0x09: return "tab"
            case 0x0D: return "enter"
            case 0x7F: return "backspace"
            case 0x20: return "space"
            case 0xF700: return "up"
            case 0xF701: return "down"
            case 0xF702: return "left"
            case 0xF703: return "right"
            case 0xF729: return "home"
            case 0xF72B: return "end"
            case 0xF72C: return "pageup"
            case 0xF72D: return "pagedown"
            case 0xF704...0xF70F: return "f\(Int(scalar.value) - 0xF703)"
            default: return raw.lowercased()
            }
        }
        return raw.lowercased()
    }
}
