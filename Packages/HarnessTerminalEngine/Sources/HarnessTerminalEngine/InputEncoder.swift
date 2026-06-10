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
public enum SpecialKey: Sendable, Equatable {
    case up, down, left, right
    case home, end, pageUp, pageDown
    case insert, deleteForward
    case escape, enter, tab, backspace
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    // F13–F20 have legacy xterm `CSI <n>~` encodings (used when Kitty is off) but Kitty reports
    // them by Private-Use-Area codepoint instead.
    case f13, f14, f15, f16, f17, f18, f19, f20
    // The keys below have NO legacy encoding — they exist only in the Kitty keyboard protocol
    // (reported as `CSI <codepoint> u`) and emit nothing when Kitty isn't enabled. Lock/system
    // keys arrive via `specialKey(for:)`; the modifier keys via `flagsChanged`.
    case capsLock, scrollLock, printScreen, pause, menu
    case leftShift, rightShift, leftControl, rightControl
    case leftAlt, rightAlt, leftSuper, rightSuper
    // Numeric keypad (F30): plain bytes normally, SS3 application forms under DECKPAM
    // (`modes.keypadApplication`), kitty functional codepoints when kitty is active.
    case keypad0, keypad1, keypad2, keypad3, keypad4
    case keypad5, keypad6, keypad7, keypad8, keypad9
    case keypadDecimal, keypadDivide, keypadMultiply
    case keypadMinus, keypadPlus, keypadEnter, keypadEquals
}

/// A key event's lifecycle phase, reported when the program enables Kitty "report event types"
/// (flag `0b10`). Press is the default (and is emitted without an event suffix); repeat/release
/// are only reported when the flag is set.
public enum KeyEventType: UInt8, Sendable {
    case press = 1
    case `repeat` = 2
    case release = 3
}

/// Mouse buttons the terminal can report.
public enum MouseButton: Int, Sendable {
    case left = 0
    case middle = 1
    case right = 2
    case wheelUp = 64
    case wheelDown = 65
    case wheelLeft = 66
    case wheelRight = 67
}

/// The kind of mouse event being reported.
public enum MouseEventKind: Sendable {
    case press
    case release
    case drag
    /// Pointer motion with NO button held — reported only under any-event tracking
    /// (DECSET 1003). Encodes as the "no button" code (3) plus the motion bit (32).
    case move
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

    public func encode(
        _ key: SpecialKey,
        modifiers: KeyModifiers = [],
        event: KeyEventType = .press,
        modes: TerminalModes = TerminalModes()
    ) -> [UInt8] {
        let flags = modes.kittyKeyboardFlags
        if flags != 0 {
            // Keys with no legacy escape form (modifier keys, keypad, F13+, lock keys) are reported
            // purely as CSI-u by their Private-Use-Area codepoint. The disambiguation-sensitive keys
            // (Esc/Enter/Tab/Backspace) also switch to CSI-u. Everything else (arrows, Home/End,
            // PageUp/Dn, Insert/Delete, F1–F12) keeps its legacy CSI form, gaining the `;mods:event`
            // sub-fields when event reporting (flag 0b10) is on.
            if let codepoint = kittyCSIuCodepoint(key) {
                return csiUFunctional(codepoint, modifiers, event, flags)
            }
            if let codepoint = disambiguationCodepoint(key) {
                return csiUFunctional(codepoint, modifiers, event, flags)
            }
            return legacySpecial(key, modifiers, event, modes)
        }
        // Kitty disabled: byte-identical to the original legacy encoding (event is irrelevant).
        return legacySpecial(key, modifiers, .press, modes)
    }

    /// The legacy (pre-Kitty) escape encoding for a key, made event-aware so that under Kitty
    /// "report event types" the functional keys carry a `:event` sub-field. Kitty-only keys
    /// (modifiers/keypad/F13+/locks) have no legacy form and return empty here.
    private func legacySpecial(_ key: SpecialKey, _ modifiers: KeyModifiers, _ event: KeyEventType, _ modes: TerminalModes) -> [UInt8] {
        let kittyOff = modes.kittyKeyboardFlags == 0
        switch key {
        case .up: return cursor("A", modifiers, modes, event)
        case .down: return cursor("B", modifiers, modes, event)
        // Option-only Left/Right send the readline/zsh-native word motions (ESC b / ESC f) — the
        // macOS terminal convention shells understand out of the box. Under Kitty the program wants
        // true modified arrows, so only apply the shortcut when Kitty is off.
        case .right:
            return (kittyOff && modifiers == [.option]) ? esc("f") : cursor("C", modifiers, modes, event)
        case .left:
            return (kittyOff && modifiers == [.option]) ? esc("b") : cursor("D", modifiers, modes, event)
        case .home: return cursor("H", modifiers, modes, event)
        case .end: return cursor("F", modifiers, modes, event)
        case .pageUp: return tilde(5, modifiers, modes, event)
        case .pageDown: return tilde(6, modifiers, modes, event)
        case .insert: return tilde(2, modifiers, modes, event)
        // Option+forward-delete deletes the next word (ESC d); otherwise the CSI 3~ form.
        case .deleteForward:
            return (kittyOff && modifiers == [.option]) ? esc("d") : tilde(3, modifiers, modes, event)
        case .f1: return ss3("P", modifiers, modes, event)
        case .f2: return ss3("Q", modifiers, modes, event)
        // Kitty reports F3 as `CSI 13~` — its CSI `R` form would collide with the cursor
        // position report (`CSI row;col R`). Legacy keeps SS3 R / CSI 1;mods R.
        case .f3:
            return kittyOff ? ss3("R", modifiers, modes, event) : tilde(13, modifiers, modes, event)
        case .f4: return ss3("S", modifiers, modes, event)
        case .f5: return tilde(15, modifiers, modes, event)
        case .f6: return tilde(17, modifiers, modes, event)
        case .f7: return tilde(18, modifiers, modes, event)
        case .f8: return tilde(19, modifiers, modes, event)
        case .f9: return tilde(20, modifiers, modes, event)
        case .f10: return tilde(21, modifiers, modes, event)
        case .f11: return tilde(23, modifiers, modes, event)
        case .f12: return tilde(24, modifiers, modes, event)
        // F13–F20 legacy xterm/VT220 codes (only reached when Kitty is off; Kitty uses CSI-u).
        case .f13: return tilde(25, modifiers, modes, event)
        case .f14: return tilde(26, modifiers, modes, event)
        case .f15: return tilde(28, modifiers, modes, event)
        case .f16: return tilde(29, modifiers, modes, event)
        case .f17: return tilde(31, modifiers, modes, event)
        case .f18: return tilde(32, modifiers, modes, event)
        case .f19: return tilde(33, modifiers, modes, event)
        case .f20: return tilde(34, modifiers, modes, event)
        // Esc/Enter/Tab/Backspace only reach here when Kitty is off (otherwise they go to CSI-u).
        case .escape: return [0x1B]
        case .enter: return [0x0D]
        // Option+Backspace deletes the previous word (ESC DEL), matching macOS terminal convention;
        // Ctrl+Backspace sends ^H (a common word-erase). Plain Backspace stays DEL (0x7F).
        case .backspace:
            if modifiers.contains(.option) { return [0x1B, 0x7F] }
            if modifiers.contains(.control) { return [0x08] }
            return [0x7F]
        case .tab:
            return modifiers.contains(.shift) ? esc("[Z") : [0x09]
        case .keypad0, .keypad1, .keypad2, .keypad3, .keypad4,
             .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
             .keypadDecimal, .keypadDivide, .keypadMultiply,
             .keypadMinus, .keypadPlus, .keypadEnter, .keypadEquals:
            return keypadLegacy(key, modes)
        default:
            return [] // Kitty-only keys (modifiers/locks) have no legacy encoding.
        }
    }

    /// DECKPAM/DECKPNM (F30): in application keypad mode the numeric keypad emits the xterm
    /// SS3 forms (`SS3 p`…`SS3 y` for 0–9, operators per the VT220 table); in numeric mode
    /// (the default) it emits the plain bytes — byte-identical to the text path the host
    /// previously fell through to, so nothing changes until a program sends `ESC =`.
    private func keypadLegacy(_ key: SpecialKey, _ modes: TerminalModes) -> [UInt8] {
        let application = modes.keypadApplication
        switch key {
        case .keypad0: return application ? esc("Op") : [0x30]
        case .keypad1: return application ? esc("Oq") : [0x31]
        case .keypad2: return application ? esc("Or") : [0x32]
        case .keypad3: return application ? esc("Os") : [0x33]
        case .keypad4: return application ? esc("Ot") : [0x34]
        case .keypad5: return application ? esc("Ou") : [0x35]
        case .keypad6: return application ? esc("Ov") : [0x36]
        case .keypad7: return application ? esc("Ow") : [0x37]
        case .keypad8: return application ? esc("Ox") : [0x38]
        case .keypad9: return application ? esc("Oy") : [0x39]
        case .keypadDecimal: return application ? esc("On") : [0x2E]
        case .keypadDivide: return application ? esc("Oo") : [0x2F]
        case .keypadMultiply: return application ? esc("Oj") : [0x2A]
        case .keypadMinus: return application ? esc("Om") : [0x2D]
        case .keypadPlus: return application ? esc("Ok") : [0x2B]
        case .keypadEnter: return application ? esc("OM") : [0x0D]
        case .keypadEquals: return application ? esc("OX") : [0x3D]
        default: return []
        }
    }

    // MARK: - Text keys

    /// Encode printable input. `text` is the layout-resolved characters (e.g. NSEvent's
    /// `charactersIgnoringModifiers` for the Control case, or `characters` otherwise).
    /// Control collapses a letter to its C0 code; Option prefixes ESC (Meta).
    public func encode(text: String, modifiers: KeyModifiers = [], modes: TerminalModes = TerminalModes()) -> [UInt8] {
        encode(text: text, shifted: nil, modifiers: modifiers, event: .press, associatedText: nil, modes: modes)
    }

    /// Kitty-rich text encoding. `text` is the *unshifted* key character (the unicode-key code);
    /// `shifted` is the character the Shift modifier produces (for the alternate-keys field);
    /// `associatedText` is the text the key actually generated (for the associated-text field).
    /// Falls back to the legacy literal/Control/Meta path when no program has opted in, so default
    /// output stays byte-identical.
    public func encode(
        text: String,
        shifted: String?,
        modifiers: KeyModifiers = [],
        event: KeyEventType = .press,
        associatedText: String? = nil,
        modes: TerminalModes = TerminalModes()
    ) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        // Progressive enhancement, gated so legacy output is byte-identical until a program opts
        // in: Kitty keyboard first, then xterm modifyOtherKeys. Both only reshape *modified* keys
        // (plain typing always falls through to the bytes below) unless report-all-keys is set.
        let flags = modes.kittyKeyboardFlags
        if flags != 0,
           let csiU = kittyEncodeText(text, shifted: shifted, modifiers: modifiers, event: event,
                                      associatedText: associatedText, flags: flags) {
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
        pixelPosition: (x: Int, y: Int)? = nil,
        modifiers: KeyModifiers = [],
        modes: TerminalModes
    ) -> [UInt8] {
        guard modes.mouseTrackingEnabled else { return [] }
        // Base button + xterm mouse modifier bits (shift 4, meta/alt 8, control 16) +
        // motion bit (32) for drags and button-less motion. Motion with no button held
        // (any-event tracking, 1003) reports the "no button" base code 3.
        var code = (kind == .move) ? 3 : button.rawValue
        if modifiers.contains(.shift) { code += 4 }
        if modifiers.contains(.option) { code += 8 }
        if modifiers.contains(.control) { code += 16 }
        if kind == .drag || kind == .move { code += 32 }
        let col = column + 1
        let line = row + 1

        // SGR-pixel (DECSET 1016): the 1006 framing with pixel coordinates, taking precedence
        // over 1006 when both are set (xterm semantics). The host supplies the pointer's
        // 0-based pixel position within the text area — the same space the XTWINOPS `CSI 14 t`
        // report uses — so programs can divide consistently. A 1016-only client whose host
        // can't produce pixels (headless) degrades to the cell-based forms below rather than
        // going silent.
        if modes.mouseSGRPixel, let pixel = pixelPosition {
            let final: Character = (kind == .release) ? "m" : "M"
            return esc("[<\(code);\(max(1, pixel.x + 1));\(max(1, pixel.y + 1))\(final)")
        }

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
        var body = Array(text.utf8)
        guard modes.bracketedPaste else { return body }
        // Defang paste injection: a clipboard payload that itself contains the bracketed-paste END
        // marker would otherwise close the paste early, so everything after it reaches the program
        // as typed input — running on paste, the exact attack bracketed paste exists to prevent.
        // Strip every embedded end marker before wrapping, like kitty/ghostty/foot. Only the 7-bit
        // `ESC[201~` form is removed: all six bytes are ASCII (< 0x80) and so can never fall inside
        // a UTF-8 multi-byte scalar in `body`, making the byte scan safe.
        stripBracketedPasteEnd(&body)
        return esc("[200~") + body + esc("[201~")
    }

    /// Remove every 7-bit bracketed-paste end marker (`ESC [ 2 0 1 ~`) from `body`, in place.
    private func stripBracketedPasteEnd(_ body: inout [UInt8]) {
        let marker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E] // ESC [ 2 0 1 ~
        // Common case — a paste with no ESC at all — touches nothing and allocates nothing.
        guard body.contains(marker[0]) else { return }
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        var i = 0
        while i < body.count {
            if body[i] == marker[0], i + marker.count <= body.count, body[i ..< i + marker.count].elementsEqual(marker) {
                i += marker.count
            } else {
                out.append(body[i])
                i += 1
            }
        }
        body = out
    }

    // MARK: - Helpers

    /// `:2` / `:3` event sub-field for repeat / release, emitted only when the program enabled
    /// Kitty "report event types" (flag 0b10). Press (1) is the default and is left implicit.
    private func eventSuffix(_ event: KeyEventType, _ flags: UInt8) -> String {
        guard flags & 0b10 != 0, event != .press else { return "" }
        return ":\(event.rawValue)"
    }

    private func cursor(_ final: Character, _ m: KeyModifiers, _ modes: TerminalModes, _ event: KeyEventType) -> [UInt8] {
        let evt = eventSuffix(event, modes.kittyKeyboardFlags)
        if m.isEmpty, evt.isEmpty {
            // Active Kitty flags supersede DECCKM: always the CSI form, never SS3 (a Kitty-mode
            // parser treats `ESC O A` as Alt+O A). Matches Ghostty, whose kitty path ignores
            // cursor-key mode entirely.
            if modes.kittyKeyboardFlags != 0 { return esc("[\(final)") }
            return modes.cursorKeysApplication ? esc("O\(final)") : esc("[\(final)")
        }
        return esc("[1;\(modifierParam(m))\(evt)\(final)")
    }

    private func ss3(_ final: Character, _ m: KeyModifiers, _ modes: TerminalModes, _ event: KeyEventType) -> [UInt8] {
        let evt = eventSuffix(event, modes.kittyKeyboardFlags)
        if m.isEmpty, evt.isEmpty {
            // Same Kitty rule as `cursor`: SS3 is a legacy-only form (F1/F2/F4 become CSI P/Q/S).
            return modes.kittyKeyboardFlags != 0 ? esc("[\(final)") : esc("O\(final)")
        }
        return esc("[1;\(modifierParam(m))\(evt)\(final)")
    }

    private func tilde(_ code: Int, _ m: KeyModifiers, _ modes: TerminalModes, _ event: KeyEventType) -> [UInt8] {
        let evt = eventSuffix(event, modes.kittyKeyboardFlags)
        if m.isEmpty, evt.isEmpty { return esc("[\(code)~") }
        return esc("[\(code);\(modifierParam(m))\(evt)~")
    }

    /// xterm modifier parameter: 1 + shift(1) + alt(2) + control(4) + meta/super(8).
    private func modifierParam(_ m: KeyModifiers) -> Int {
        var value = 1
        if m.contains(.shift) { value += 1 }
        if m.contains(.option) { value += 2 }
        if m.contains(.control) { value += 4 }
        if m.contains(.command) { value += 8 }
        return value
    }

    // MARK: - Kitty keyboard protocol (CSI u) + modifyOtherKeys

    /// CSI-u for a functional / disambiguation key (no alternate-key sub-fields): `CSI codepoint u`
    /// or `CSI codepoint ; mods[:event] u`.
    private func csiUFunctional(_ codepoint: UInt32, _ m: KeyModifiers, _ event: KeyEventType, _ flags: UInt8) -> [UInt8] {
        let mod = modifierParam(m)
        let evt = eventSuffix(event, flags)
        if mod == 1, evt.isEmpty { return esc("[\(codepoint)u") }
        return esc("[\(codepoint);\(mod)\(evt)u")
    }

    /// Codepoint for the disambiguation-sensitive keys that switch to CSI-u under any active flags.
    private func disambiguationCodepoint(_ key: SpecialKey) -> UInt32? {
        switch key {
        case .escape: return 27
        case .enter: return 13
        case .tab: return 9
        case .backspace: return 127
        default: return nil
        }
    }

    /// Private-Use-Area codepoints for keys that Kitty reports as `CSI codepoint u` rather than a
    /// legacy CSI form. F13–F20 also have a legacy `~` form (used only when Kitty is off); the rest
    /// have no legacy encoding at all. Numbers transcribed from the kitty keyboard-protocol
    /// "Functional key definitions" table; verify against `kitty +kitten show_key -m kitty`.
    /// Returns nil for keys that keep their legacy encoding under Kitty (arrows, F1–F12, …).
    private func kittyCSIuCodepoint(_ key: SpecialKey) -> UInt32? {
        switch key {
        case .f13: return 57376
        case .f14: return 57377
        case .f15: return 57378
        case .f16: return 57379
        case .f17: return 57380
        case .f18: return 57381
        case .f19: return 57382
        case .f20: return 57383
        case .capsLock: return 57358
        case .scrollLock: return 57359
        case .printScreen: return 57361
        case .pause: return 57362
        case .menu: return 57363
        case .leftShift: return 57441
        case .rightShift: return 57447
        case .leftControl: return 57442
        case .rightControl: return 57448
        case .leftAlt: return 57443
        case .rightAlt: return 57449
        case .leftSuper: return 57444
        case .rightSuper: return 57450
        // Kitty functional keypad codepoints (the kitty keyboard protocol's KP_* block).
        case .keypad0: return 57399
        case .keypad1: return 57400
        case .keypad2: return 57401
        case .keypad3: return 57402
        case .keypad4: return 57403
        case .keypad5: return 57404
        case .keypad6: return 57405
        case .keypad7: return 57406
        case .keypad8: return 57407
        case .keypad9: return 57408
        case .keypadDecimal: return 57409
        case .keypadDivide: return 57410
        case .keypadMultiply: return 57411
        case .keypadMinus: return 57412
        case .keypadPlus: return 57413
        case .keypadEnter: return 57414
        case .keypadEquals: return 57415
        default: return nil
        }
    }

    /// CSI-u for a printable key when Kitty keyboard is active. Plain (un-Ctrl/Alt) typing falls
    /// through to legacy text unless `report-all-keys-as-escape` (bit 8) is set. The key code is
    /// the unshifted character (Kitty convention); Shift is carried in the modifiers, with the
    /// shifted character surfaced separately via the alternate-keys field.
    private func kittyEncodeText(
        _ text: String,
        shifted: String?,
        modifiers m: KeyModifiers,
        event: KeyEventType,
        associatedText: String?,
        flags: UInt8
    ) -> [UInt8]? {
        guard let scalar = text.unicodeScalars.first else { return nil }
        let modified = m.contains(.control) || m.contains(.option) || m.contains(.command)
        let allKeysEscape = (flags & 0x08) != 0
        guard modified || allKeysEscape else { return nil } // plain text → legacy path

        var key = scalar.value
        if key >= 0x41, key <= 0x5A { key += 0x20 } // A–Z → a–z; Shift stays in the modifier bits

        // Alternate keys (flag 0b100): the shifted key (only when Shift is held and it differs from
        // the unshifted key code) and the base-layout key (only when it differs). We approximate the
        // base-layout key with the unshifted scalar (exact for US-ASCII; full layout mapping would
        // need UCKeyTranslate against the US keyboard).
        var shiftedCode: UInt32?
        var baseCode: UInt32?
        if flags & 0b100 != 0 {
            if m.contains(.shift), let sh = shifted?.unicodeScalars.first?.value, sh != key {
                shiftedCode = sh
            }
            if scalar.value != key { baseCode = scalar.value }
        }

        // Associated text (flag 0b10000): the printable text the key produced. Control-modified keys
        // produce no associated text per the spec.
        var textCodepoints: [UInt32] = []
        if flags & 0x10 != 0, !m.contains(.control), let at = associatedText {
            textCodepoints = at.unicodeScalars.map(\.value).filter { $0 >= 0x20 }
        }

        return csiUText(key: key, shifted: shiftedCode, base: baseCode, modifiers: m,
                        event: event, textCodepoints: textCodepoints, flags: flags)
    }

    /// Assemble the full Kitty CSI-u form for a text key:
    /// `CSI key[:shifted[:base]] ; mods[:event] ; text u`. Trailing default fields are omitted;
    /// an interior default field is left empty (e.g. `key;;text` when mods is default but text
    /// follows, or `key::base` when shifted is absent but base present).
    private func csiUText(
        key: UInt32, shifted: UInt32?, base: UInt32?,
        modifiers: KeyModifiers, event: KeyEventType, textCodepoints: [UInt32], flags: UInt8
    ) -> [UInt8] {
        var keyField = "\(key)"
        if shifted != nil || base != nil {
            keyField += ":" + (shifted.map(String.init) ?? "")
            if let base { keyField += ":\(base)" }
        }
        let mod = modifierParam(modifiers)
        let evt = eventSuffix(event, flags)
        let modField = (mod != 1 || !evt.isEmpty) ? "\(mod)\(evt)" : ""
        let textField = textCodepoints.map(String.init).joined(separator: ":")

        var s = keyField
        if !textField.isEmpty {
            s += ";\(modField);\(textField)"
        } else if !modField.isEmpty {
            s += ";\(modField)"
        }
        return esc("[\(s)u")
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
