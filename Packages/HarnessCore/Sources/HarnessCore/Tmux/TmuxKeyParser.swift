import Foundation

/// Parses tmux/Ghostty-style key tokens into raw bytes that can be written to
/// a PTY (or sent via libghostty's send-text path). Mirrors `tmux send-keys`
/// behavior: `C-c`, `M-x`, `S-a`, `Enter`, `Tab`, `Space`, `Esc`, `Up`, etc.
public enum TmuxKeyParser {
    public static func encode(keys: [String]) -> Data {
        var out = Data()
        for token in keys {
            out.append(encode(token: token))
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

        // Recursively encode the tail so we can compose with named keys (e.g. M-Up).
        let tail = encode(token: remaining)

        var out = Data()
        if meta { out.append(0x1B) }
        if ctrl, tail.count == 1, let byte = tail.first {
            // Translate to standard control byte (0x01 for Ctrl-A, etc).
            let lower = Character(UnicodeScalar(byte)).lowercased().first
            if let scalar = lower?.asciiValue, scalar >= 0x60, scalar < 0x80 {
                out.append(scalar - 0x60)
            } else if byte >= 0x40, byte < 0x60 {
                out.append(byte - 0x40)
            } else {
                out.append(byte)
            }
            _ = shift // shift on plain letters is encoded by the letter case the user passes
        } else {
            out.append(tail)
        }
        return out
    }
}
