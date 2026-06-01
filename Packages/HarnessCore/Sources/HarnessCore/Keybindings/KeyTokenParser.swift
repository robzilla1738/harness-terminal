import Foundation

/// Parses Harness key tokens into the raw byte sequence a PTY expects when
/// the user (or an agent script) sends them. Handles control/meta/shift
/// modifiers (`C-c`, `M-x`, `S-Tab`, chained `C-M-x`), the standard named
/// keys (`Enter`, `Tab`, `Space`, `Esc`, `Backspace`, `Delete`, arrows,
/// `Home`, `End`, `PageUp`, `PageDown`, `F1`–`F12`), and falls through to
/// the literal UTF-8 bytes for anything else.
///
/// The token vocabulary is intentionally compact and stable so it can appear
/// in `keybindings.json`, `harness-cli send-keys`, and agent hooks without
/// version drift. The same grammar is what `KeySpec.parse` accepts on the
/// modifier side.
public enum KeyTokenParser {
    public static func encode(keys: [String]) -> Data {
        var out = Data()
        for token in keys {
            out.append(encode(token: token))
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

    public static func encode(token: String) -> Data {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return Data() }

        // C-x, M-x, S-x prefix combinations (chained, e.g. "C-M-x").
        if let combined = encodeModifiers(trimmed) {
            return combined
        }

        switch trimmed.lowercased() {
        case "enter", "return", "ret": return Data([0x0D])
        case "tab": return Data([0x09])
        case "space": return Data([0x20])
        case "backspace", "bs": return Data([0x7F])
        case "delete", "del": return ansi("[3~")
        case "escape", "esc": return Data([0x1B])
        case "up": return ansi("[A")
        case "down": return ansi("[B")
        case "right": return ansi("[C")
        case "left": return ansi("[D")
        case "home": return ansi("[H")
        case "end": return ansi("[F")
        case "pageup", "pgup": return ansi("[5~")
        case "pagedown", "pgdn": return ansi("[6~")
        case "f1": return ansi("OP")
        case "f2": return ansi("OQ")
        case "f3": return ansi("OR")
        case "f4": return ansi("OS")
        case "f5": return ansi("[15~")
        case "f6": return ansi("[17~")
        case "f7": return ansi("[18~")
        case "f8": return ansi("[19~")
        case "f9": return ansi("[20~")
        case "f10": return ansi("[21~")
        case "f11": return ansi("[23~")
        case "f12": return ansi("[24~")
        default:
            return Data(trimmed.utf8)
        }
    }

    private static func ansi(_ tail: String) -> Data {
        var data = Data([0x1B])
        data.append(Data(tail.utf8))
        return data
    }

    /// Handles `C-x`, `M-x`, `S-x`, and chained forms `C-M-x` / `M-S-x` / etc.
    private static func encodeModifiers(_ token: String) -> Data? {
        var ctrl = false
        var meta = false
        var shift = false
        var remaining = token

        while remaining.count >= 2, remaining[remaining.index(remaining.startIndex, offsetBy: 1)] == "-" {
            switch remaining.first {
            case "C", "c": ctrl = true
            case "M", "m": meta = true
            case "S", "s": shift = true
            default: return nil
            }
            remaining = String(remaining.dropFirst(2))
        }

        if remaining.isEmpty { return nil }
        // No modifiers detected? Let the caller fall through.
        if !ctrl && !meta && !shift { return nil }

        let key = remaining.lowercased()

        // Modifier-aware named keys use xterm's parameterized CSI form, matching the engine's
        // InputEncoder so `send-keys S-Up` sends the same bytes a physical Shift+Up does. Without
        // this, S- (and C-/M-) on a named key was silently dropped to the bare key. Shift+Tab is
        // the one special editing case (back-tab / CBT).
        if key == "tab", shift, !ctrl, !meta {
            return ansi("[Z")
        }
        if let seq = modifiedNamedKey(key, param: modifierParam(ctrl: ctrl, meta: meta, shift: shift)) {
            return seq
        }

        // A plain character (or a key with no CSI modifier form, e.g. Enter/Space/Esc): keep the
        // legacy Control-collapses-to-C0 / Meta-prefixes-ESC behavior. Shift on a letter is
        // conveyed by the letter case the user passes (S-a vs S-A).
        let tail = encode(token: remaining)
        var out = Data()
        if meta { out.append(0x1B) }
        if ctrl, tail.count == 1, let byte = tail.first {
            let lower = Character(UnicodeScalar(byte)).lowercased().first
            if let scalar = lower?.asciiValue, scalar >= 0x60, scalar < 0x80 {
                out.append(scalar - 0x60)
            } else if byte >= 0x40, byte < 0x60 {
                out.append(byte - 0x40)
            } else {
                out.append(byte)
            }
        } else {
            out.append(tail)
        }
        return out
    }

    /// xterm modifier parameter: 1 + shift(1) + meta/alt(2) + ctrl(4). Matches
    /// `InputEncoder.modifierParam` so a token's bytes equal the physical keypress's.
    private static func modifierParam(ctrl: Bool, meta: Bool, shift: Bool) -> Int {
        1 + (shift ? 1 : 0) + (meta ? 2 : 0) + (ctrl ? 4 : 0)
    }

    /// The xterm CSI form of a modifier-aware named key (cursor / function / editing), or nil if
    /// `name` isn't one. `param` comes from `modifierParam`. Mirrors InputEncoder's cursor/ss3/
    /// tilde helpers: cursor keys + F1–F4 → `ESC[1;<param><final>`; editing + F5–F12 →
    /// `ESC[<code>;<param>~`.
    private static func modifiedNamedKey(_ name: String, param: Int) -> Data? {
        let cursorFinals: [String: Character] = [
            "up": "A", "down": "B", "right": "C", "left": "D", "home": "H", "end": "F",
            "f1": "P", "f2": "Q", "f3": "R", "f4": "S",
        ]
        if let final = cursorFinals[name] { return ansi("[1;\(param)\(final)") }
        let tildeCodes: [String: Int] = [
            "delete": 3, "del": 3, "pageup": 5, "pgup": 5, "pagedown": 6, "pgdn": 6,
            "f5": 15, "f6": 17, "f7": 18, "f8": 19, "f9": 20, "f10": 21, "f11": 23, "f12": 24,
        ]
        if let code = tildeCodes[name] { return ansi("[\(code);\(param)~") }
        return nil
    }
}
