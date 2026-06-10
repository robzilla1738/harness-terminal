import Foundation

/// Parses Harness key tokens (`C-c`, `M-x`, `S-Tab`, chained `C-M-x`, named keys like `Enter`,
/// `Up`, `F5`, and literal text) into the raw bytes a PTY expects — by resolving each token to the
/// engine's `SpecialKey`/`KeyModifiers` vocabulary and delegating the byte encoding to
/// `InputEncoder`. There is therefore exactly **one** escape-sequence encoder in the codebase:
/// `send-keys` / keybindings now emit the same bytes a physical keypress would (including
/// mode-dependent forms when a caller supplies the target's `TerminalModes`), instead of a second
/// hand-maintained table that had to be kept in agreement with the engine by hand.
///
/// The token vocabulary is intentionally compact and stable so it can appear in `keybindings.json`,
/// `harness-cli send-keys`, and agent hooks without version drift. The same grammar is what
/// `KeySpec.parse` accepts on the modifier side.
public enum KeyTokenParser {
    public static func encode(keys: [String], modes: TerminalModes = TerminalModes()) -> Data {
        var out = Data()
        for token in keys {
            out.append(encode(token: token, modes: modes))
        }
        return out
    }

    /// `send-keys -H`: each token is a hex byte (`1b`, `0x5b`, `41`). Non-hex tokens are
    /// skipped. Lets scripts inject raw byte sequences a terminal program expects.
    public static func hexBytes(_ keys: [String]) -> Data {
        var out = Data()
        for token in keys {
            let t = token.hasPrefix("0x") || token.hasPrefix("0X") ? String(token.dropFirst(2)) : token
            if let byte = UInt8(t, radix: 16) { out.append(byte) }
        }
        return out
    }

    public static func encode(token: String, modes: TerminalModes = TerminalModes()) -> Data {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Data() }

        let (modifiers, key) = splitModifiers(trimmed)
        let encoder = InputEncoder()

        // A named special key (cursor / editing / function / Enter / Tab / …): the engine owns its
        // escape form, honoring the modifier param and the supplied modes (DECCKM, Kitty).
        if let special = specialKey(for: key) {
            return Data(encoder.encode(special, modifiers: modifiers, modes: modes))
        }

        // Anything else is literal text. `Space` is the one named token that maps to a literal
        // character (a space) rather than a SpecialKey. With no modifiers it's the raw UTF-8 (a
        // plain `send-keys foo` types "foo"); with Ctrl/Alt/Shift the engine applies
        // Control-to-C0 collapse and Meta-prefixes-ESC exactly as a physical keypress would.
        let text = key.lowercased() == "space" ? " " : key
        if modifiers.isEmpty {
            return Data(text.utf8)
        }
        return Data(encoder.encode(text: text, modifiers: modifiers, modes: modes))
    }

    /// Strip a chained `C-`/`M-`/`S-` modifier prefix, returning the modifiers and the remaining
    /// (lowercased) key token. `C-`/`c-` → Control, `M-`/`m-` → Option/Meta, `S-`/`s-` → Shift.
    private static func splitModifiers(_ token: String) -> (KeyModifiers, String) {
        var modifiers: KeyModifiers = []
        var remaining = token
        while remaining.count >= 2,
              remaining[remaining.index(remaining.startIndex, offsetBy: 1)] == "-" {
            switch remaining.first {
            case "C", "c": modifiers.insert(.control)
            case "M", "m": modifiers.insert(.option)
            case "S", "s": modifiers.insert(.shift)
            default:
                // Not a modifier prefix (e.g. a literal "x-y") — stop stripping.
                return (modifiers, modifiers.isEmpty ? token : remaining)
            }
            remaining = String(remaining.dropFirst(2))
        }
        // A bare key keeps its original case (so a literal "A" stays "A"); a modified key is matched
        // case-insensitively against the named-key table.
        return (modifiers, modifiers.isEmpty ? remaining : remaining.lowercased())
    }

    /// Map a (lowercased) named token to the engine's `SpecialKey`, or nil for literal text.
    /// Mirrors tmux/xterm key names; `space` is intentionally absent (it's literal text).
    private static func specialKey(for name: String) -> SpecialKey? {
        switch name.lowercased() {
        case "enter", "return", "ret": return .enter
        case "tab": return .tab
        case "backspace", "bs": return .backspace
        case "escape", "esc": return .escape
        case "delete", "del": return .deleteForward
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        case "home": return .home
        case "end": return .end
        case "pageup", "pgup": return .pageUp
        case "pagedown", "pgdn": return .pageDown
        case "f1": return .f1
        case "f2": return .f2
        case "f3": return .f3
        case "f4": return .f4
        case "f5": return .f5
        case "f6": return .f6
        case "f7": return .f7
        case "f8": return .f8
        case "f9": return .f9
        case "f10": return .f10
        case "f11": return .f11
        case "f12": return .f12
        default: return nil
        }
    }
}
