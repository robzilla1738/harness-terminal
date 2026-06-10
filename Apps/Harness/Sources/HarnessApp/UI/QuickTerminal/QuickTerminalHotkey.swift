import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hotkey via Carbon `RegisterEventHotKey` — which fires even when
/// Harness is in the background and needs no Accessibility permission — and invokes `onPressed`
/// when it's struck. The Carbon C-interop is isolated here, away from the controller.
@MainActor
final class QuickTerminalHotkey {
    private let onPressed: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    init(onPressed: @escaping () -> Void) {
        self.onPressed = onPressed
    }

    /// (Re)register for `spec` (the `mod-mod-key` form used by `prefixKey`, e.g. `cmd-opt-\``).
    /// Replaces any prior binding; an unparseable spec (or one with no modifier) just leaves the
    /// hotkey disabled rather than swallowing a bare key globally.
    func register(spec: String) {
        installHandlerIfNeeded()
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        guard let parsed = Self.parse(spec) else { return }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(parsed.keyCode, parsed.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // Registration can fail — most commonly `eventHotKeyExists` when another app already
            // owns the combo. The old binding was already unregistered above, so don't leave a
            // stale/partial ref around, and surface it instead of silently leaving the user with
            // no working quick-terminal hotkey.
            hotKeyRef = nil
            NSLog("Harness: quick-terminal hotkey '\(spec)' could not be registered (OSStatus \(status)); it may already be in use by another app.")
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
    }

    fileprivate func fire() { onPressed() }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), Self.handler, 1, &spec, context, &eventHandler)
    }

    /// A unique-enough four-char signature (`'HQTk'`) for our single hot key.
    private static let signature: OSType = Array("HQTk".utf8).reduce(0) { ($0 << 8) | OSType($1) }

    // Carbon delivers hot-key events on the main run loop, so we're already main-isolated when this
    // fires — `assumeIsolated` bridges into the @MainActor instance without an async hop. The raw
    // `context` pointer is passed across the isolation boundary as its (Sendable) bit pattern and
    // rebuilt inside, so the concurrency checker sees nothing non-Sendable cross over.
    private static let handler: EventHandlerUPP = { _, _, context in
        guard let context else { return noErr }
        let pointerBits = Int(bitPattern: context)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: pointerBits) else { return }
            Unmanaged<QuickTerminalHotkey>.fromOpaque(pointer).takeUnretainedValue().fire()
        }
        return noErr
    }

    // MARK: - Parsing

    private static func parse(_ spec: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        let parts = spec.lowercased().split(separator: "-").map(String.init)
        guard let keyToken = parts.last else { return nil }
        var modifiers: UInt32 = 0
        for token in parts.dropLast() {
            switch token {
            case "cmd", "command": modifiers |= UInt32(cmdKey)
            case "opt", "alt", "option": modifiers |= UInt32(optionKey)
            case "ctrl", "control": modifiers |= UInt32(controlKey)
            case "shift": modifiers |= UInt32(shiftKey)
            default: return nil
            }
        }
        // A global hotkey with no modifier would intercept ordinary typing everywhere — refuse it.
        guard modifiers != 0, let code = keyCode(for: keyToken) else { return nil }
        return (UInt32(code), modifiers)
    }

    private static func keyCode(for token: String) -> Int? {
        if let named = namedKeys[token] { return named }
        if token.hasPrefix("f"), let n = Int(token.dropFirst()), let fkey = functionKeys[n] { return fkey }
        return ansiKeys[token]
    }

    private static let namedKeys: [String: Int] = [
        "escape": kVK_Escape, "esc": kVK_Escape,
        "tab": kVK_Tab,
        "enter": kVK_Return, "return": kVK_Return,
        "space": kVK_Space,
        "backspace": kVK_Delete, "delete": kVK_Delete,
        "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "grave": kVK_ANSI_Grave,
    ]

    private static let functionKeys: [Int: Int] = [
        1: kVK_F1, 2: kVK_F2, 3: kVK_F3, 4: kVK_F4, 5: kVK_F5, 6: kVK_F6,
        7: kVK_F7, 8: kVK_F8, 9: kVK_F9, 10: kVK_F10, 11: kVK_F11, 12: kVK_F12,
    ]

    private static let ansiKeys: [String: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal,
        "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
    ]
}
