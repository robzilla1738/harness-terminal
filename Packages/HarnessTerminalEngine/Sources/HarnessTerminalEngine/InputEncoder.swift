import Foundation

/// Keyboard modifiers relevant to terminal input encoding.
public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1) // "Meta" / Alt
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}

/// Non-text keys that map to escape sequences.
public enum SpecialKey: Sendable {
    case up, down, left, right
    case home, end, pageUp, pageDown
    case insert, deleteForward
    case escape, enter, tab, backspace
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

/// Encodes keyboard input into the bytes a terminal application expects, honoring the
/// terminal's current modes (DECCKM application-cursor keys, etc.). Pure VT logic with no
/// AppKit dependency — the NSView host maps `NSEvent` to these calls, which keeps the
/// tricky encoding rules unit-testable.
///
/// Follows xterm conventions: CSI/SS3 cursor + function keys, `1;<mod>` modifier params,
/// Control collapsing letters to C0 codes, and Option-as-Meta prefixing ESC.
public struct InputEncoder: Sendable {
    public init() {}

    // MARK: - Special keys

    public func encode(_ key: SpecialKey, modifiers: KeyModifiers = [], modes: TerminalModes = TerminalModes()) -> [UInt8] {
        switch key {
        case .up: return cursor("A", modifiers, modes)
        case .down: return cursor("B", modifiers, modes)
        case .right: return cursor("C", modifiers, modes)
        case .left: return cursor("D", modifiers, modes)
        case .home: return cursor("H", modifiers, modes)
        case .end: return cursor("F", modifiers, modes)
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .insert: return tilde(2, modifiers)
        case .deleteForward: return tilde(3, modifiers)
        case .f1: return ss3("P", modifiers)
        case .f2: return ss3("Q", modifiers)
        case .f3: return ss3("R", modifiers)
        case .f4: return ss3("S", modifiers)
        case .f5: return tilde(15, modifiers)
        case .f6: return tilde(17, modifiers)
        case .f7: return tilde(18, modifiers)
        case .f8: return tilde(19, modifiers)
        case .f9: return tilde(20, modifiers)
        case .f10: return tilde(21, modifiers)
        case .f11: return tilde(23, modifiers)
        case .f12: return tilde(24, modifiers)
        case .escape: return [0x1B]
        case .enter: return [0x0D]
        case .backspace: return [0x7F]
        case .tab:
            return modifiers.contains(.shift) ? esc("[Z") : [0x09]
        }
    }

    // MARK: - Text keys

    /// Encode printable input. `text` is the layout-resolved characters (e.g. NSEvent's
    /// `charactersIgnoringModifiers` for the Control case, or `characters` otherwise).
    /// Control collapses a letter to its C0 code; Option prefixes ESC (Meta).
    public func encode(text: String, modifiers: KeyModifiers = []) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        var bytes = Array(text.utf8)
        if modifiers.contains(.control), let control = controlByte(for: text) {
            bytes = [control]
        }
        if modifiers.contains(.option) {
            bytes.insert(0x1B, at: 0)
        }
        return bytes
    }

    /// Wrap pasted text in bracketed-paste markers when the mode is enabled.
    public func encodePaste(_ text: String, modes: TerminalModes) -> [UInt8] {
        let body = Array(text.utf8)
        guard modes.bracketedPaste else { return body }
        return esc("[200~") + body + esc("[201~")
    }

    // MARK: - Helpers

    private func cursor(_ final: Character, _ m: KeyModifiers, _ modes: TerminalModes) -> [UInt8] {
        if m.isEmpty {
            return modes.cursorKeysApplication ? esc("O\(final)") : esc("[\(final)")
        }
        return esc("[1;\(modifierParam(m))\(final)")
    }

    private func ss3(_ final: Character, _ m: KeyModifiers) -> [UInt8] {
        m.isEmpty ? esc("O\(final)") : esc("[1;\(modifierParam(m))\(final)")
    }

    private func tilde(_ code: Int, _ m: KeyModifiers) -> [UInt8] {
        m.isEmpty ? esc("[\(code)~") : esc("[\(code);\(modifierParam(m))~")
    }

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + control(4) + meta(8).
    private func modifierParam(_ m: KeyModifiers) -> Int {
        var value = 1
        if m.contains(.shift) { value += 1 }
        if m.contains(.option) { value += 2 }
        if m.contains(.control) { value += 4 }
        if m.contains(.command) { value += 8 }
        return value
    }

    private func controlByte(for text: String) -> UInt8? {
        guard let scalar = text.unicodeScalars.first, scalar.value < 128 else { return nil }
        let v = scalar.value
        // Letters and @ [ \ ] ^ _ ` collapse to C0 via & 0x1F; space -> NUL.
        if (v >= 0x40 && v <= 0x7F) {
            return UInt8(v & 0x1F)
        }
        if v == 0x20 { return 0 }
        return nil
    }

    private func esc(_ s: String) -> [UInt8] {
        [0x1B] + Array(s.utf8)
    }
}
