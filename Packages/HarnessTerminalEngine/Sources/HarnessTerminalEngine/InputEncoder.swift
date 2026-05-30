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

/// Mouse buttons the terminal can report.
public enum MouseButton: Int, Sendable {
    case left = 0
    case middle = 1
    case right = 2
    case wheelUp = 64
    case wheelDown = 65
}

/// The kind of mouse event being reported.
public enum MouseEventKind: Sendable {
    case press
    case release
    case drag
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
        // Progressive enhancement: when a program has enabled the Kitty keyboard protocol, the
        // disambiguation-sensitive keys (Esc/Enter/Tab/Backspace) go out in unambiguous CSI-u
        // form. Arrows/function keys keep their legacy CSI forms (which already carry modifier
        // params), matching Kitty's "legacy functional keys" handling. When no flags are set this
        // returns nil and the legacy switch below runs byte-for-byte unchanged.
        if modes.kittyKeyboardFlags != 0, let csiU = kittyEncodeSpecial(key, modifiers) {
            return csiU
        }
        switch key {
        case .up: return cursor("A", modifiers, modes)
        case .down: return cursor("B", modifiers, modes)
        // Option-only Left/Right send the readline/zsh-native word motions (ESC b / ESC f) —
        // the Terminal.app & Ghostty default that shell line editors understand out of the box.
        // Every other modifier combo keeps the xterm CSI form so TUIs that read modified arrows
        // are unaffected.
        case .right:
            return modifiers == [.option] ? esc("f") : cursor("C", modifiers, modes)
        case .left:
            return modifiers == [.option] ? esc("b") : cursor("D", modifiers, modes)
        case .home: return cursor("H", modifiers, modes)
        case .end: return cursor("F", modifiers, modes)
        case .pageUp: return tilde(5, modifiers)
        case .pageDown: return tilde(6, modifiers)
        case .insert: return tilde(2, modifiers)
        // Option+forward-delete deletes the next word (ESC d); otherwise the CSI 3~ form.
        case .deleteForward:
            return modifiers == [.option] ? esc("d") : tilde(3, modifiers)
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
        // Option+Backspace deletes the previous word (ESC DEL), matching Terminal.app/Ghostty;
        // Ctrl+Backspace sends ^H (a common word-erase). Plain Backspace stays DEL (0x7F).
        case .backspace:
            if modifiers.contains(.option) { return [0x1B, 0x7F] }
            if modifiers.contains(.control) { return [0x08] }
            return [0x7F]
        case .tab:
            return modifiers.contains(.shift) ? esc("[Z") : [0x09]
        }
    }

    // MARK: - Text keys

    /// Encode printable input. `text` is the layout-resolved characters (e.g. NSEvent's
    /// `charactersIgnoringModifiers` for the Control case, or `characters` otherwise).
    /// Control collapses a letter to its C0 code; Option prefixes ESC (Meta).
    public func encode(text: String, modifiers: KeyModifiers = [], modes: TerminalModes = TerminalModes()) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        // Progressive enhancement, gated so legacy output is byte-identical until a program opts
        // in: Kitty keyboard first, then xterm modifyOtherKeys. Both only reshape *modified* keys
        // (plain typing always falls through to the bytes below).
        if modes.kittyKeyboardFlags != 0, let csiU = kittyEncodeText(text, modifiers, flags: modes.kittyKeyboardFlags) {
            return csiU
        }
        if modes.modifyOtherKeys >= 1, let other = modifyOtherKeysEncode(text, modifiers) {
            return other
        }
        var bytes = Array(text.utf8)
        if modifiers.contains(.control), let control = controlByte(for: text) {
            bytes = [control]
        }
        if modifiers.contains(.option) {
            bytes.insert(0x1B, at: 0)
        }
        return bytes
    }

    // MARK: - Mouse

    /// Encode a mouse event for the active tracking mode. Uses SGR 1006 when the app
    /// enabled it (the modern, coordinate-unbounded form), otherwise the legacy X10/normal
    /// byte form. `column`/`row` are 0-based; the wire protocol is 1-based. Returns empty
    /// when no mouse-tracking mode is active.
    public func encodeMouse(
        button: MouseButton,
        kind: MouseEventKind,
        column: Int,
        row: Int,
        modifiers: KeyModifiers = [],
        modes: TerminalModes
    ) -> [UInt8] {
        guard modes.mouseTrackingEnabled else { return [] }
        // Base button + xterm mouse modifier bits (shift 4, meta/alt 8, control 16) +
        // motion bit (32) for drags.
        var code = button.rawValue
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if kind == .drag { code += 32 }
        let col = column + 1
        let line = row + 1

        if modes.mouseSGR {
            let final: Character = (kind == .release) ? "m" : "M"
            return esc("[<\(code);\(col);\(line)\(final)")
        }

        // Legacy X10: CSI M Cb Cx Cy, each value offset by 32; release reports button 3.
        var legacy = code
        if kind == .release { legacy = (legacy & ~0b11) | 3 }
        let cb = UInt8(clamping: legacy + 32)
        let cx = UInt8(clamping: min(col, 223) + 32)
        let cy = UInt8(clamping: min(line, 223) + 32)
        return [0x1B, 0x5B, 0x4D, cb, cx, cy] // ESC [ M …
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

    // MARK: - Kitty keyboard protocol (CSI u) + modifyOtherKeys

    /// Kitty modifier encoding: 1 + shift(1) + alt(2) + ctrl(4) + super(8).
    private func kittyModifier(_ m: KeyModifiers) -> Int { modifierParam(m) }

    /// `CSI <key>u` (no mods) or `CSI <key>;<mods>u`.
    private func csiU(_ key: UInt32, _ m: KeyModifiers) -> [UInt8] {
        let mod = kittyModifier(m)
        return mod == 1 ? esc("[\(key)u") : esc("[\(key);\(mod)u")
    }

    /// CSI-u for a printable key when Kitty keyboard is active. Plain (un-Ctrl/Alt) typing falls
    /// through to legacy text unless `report-all-keys-as-escape` (bit 8) is set. The key code is
    /// the unshifted ASCII letter (Kitty convention), with Shift carried in the modifiers.
    private func kittyEncodeText(_ text: String, _ m: KeyModifiers, flags: UInt8) -> [UInt8]? {
        guard let scalar = text.unicodeScalars.first else { return nil }
        let modified = m.contains(.control) || m.contains(.option) || m.contains(.command)
        let allKeysEscape = (flags & 0x08) != 0
        guard modified || allKeysEscape else { return nil } // plain text → legacy path
        var key = scalar.value
        if key >= 0x41, key <= 0x5A { key += 0x20 } // A–Z → a–z; Shift stays in the modifier bits
        return csiU(key, m)
    }

    /// CSI-u for the disambiguation-sensitive special keys (others keep their legacy CSI forms).
    private func kittyEncodeSpecial(_ key: SpecialKey, _ m: KeyModifiers) -> [UInt8]? {
        let code: UInt32
        switch key {
        case .escape: code = 27
        case .enter: code = 13
        case .tab: code = 9
        case .backspace: code = 127
        default: return nil
        }
        return csiU(code, m)
    }

    /// xterm modifyOtherKeys (`CSI 27 ; <mod> ; <cp> ~`) — only reshapes Ctrl/Alt-modified keys.
    private func modifyOtherKeysEncode(_ text: String, _ m: KeyModifiers) -> [UInt8]? {
        guard m.contains(.control) || m.contains(.option),
              let scalar = text.unicodeScalars.first else { return nil }
        return esc("[27;\(modifierParam(m));\(scalar.value)~")
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
