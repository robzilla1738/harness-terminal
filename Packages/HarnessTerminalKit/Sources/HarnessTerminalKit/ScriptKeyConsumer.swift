import AppKit
import HarnessCore
import HarnessTerminalEngine

/// Turns a key into the config-file chord and swallows it when the published keymap says so.
/// Lua functions are not in the manifest, so they never run here.
@MainActor
final class ScriptKeyConsumer {
    private var keymap = ScriptKeymap()
    private var loaded = false
    private var stamp: Date?
    private let manifest: () -> ScriptManifest?
    private let modified: () -> Date?
    private let perform: (String) -> Void

    init(
        // Never publish on the key path: an edited init.lua republishes in the background
        // and the next key after that sees the new stamp.
        manifest: @escaping () -> ScriptManifest? = {
            ScriptActionRunner.syncManifestInBackground()
            return ScriptStore.load()
        },
        modified: @escaping () -> Date? = { ScriptActionRunner.stamp() },
        perform: @escaping (String) -> Void
    ) {
        self.manifest = manifest
        self.modified = modified
        self.perform = perform
    }

    func consume(_ event: NSEvent) -> Bool {
        reload()
        let named = ScriptChordEvent.named(event)
        let physical = ScriptChordEvent.physical(event)
        let chord: ScriptChord
        if let named {
            chord = keymap.chordToPress(named: named, physical: physical)
        } else if keymap.stack.last.flatMap({ keymap.modes[$0]?.exclusive }) == true {
            chord = ScriptChord(key: "unmapped")
        } else {
            return false
        }
        let delivery = keymap.press(chord) { _ in false }
        if case let .consumed(.action(name)) = delivery {
            perform(name)
        }
        switch delivery {
        case .forward: return false
        case .partial, .cancelled, .leftMode, .consumed: return true
        }
    }

    private func reload() {
        let date = modified()
        if loaded, date == stamp { return }
        if let manifest = manifest() {
            keymap = ScriptKeymap.replay(bindings: manifest.bindings, modes: manifest.modes)
        } else {
            keymap = ScriptKeymap()
        }
        stamp = modified()
        loaded = true
    }
}

@MainActor
enum ScriptChordEvent {
    static func named(_ event: NSEvent) -> ScriptChord? {
        let modifiers = modifiers(of: event)
        if let special = HarnessTerminalSurfaceView.specialKey(for: event), let name = scriptName(special) {
            return ScriptChord(modifiers: modifiers, key: name)
        }
        guard let row = usKeys[event.keyCode] else { return nil }
        return ScriptChord(modifiers: modifiers, key: row.key)
    }

    static func physical(_ event: NSEvent) -> ScriptChord? {
        guard let row = usKeys[event.keyCode] else { return nil }
        return ScriptChord(modifiers: modifiers(of: event), key: row.code, physical: true)
    }

    private static func modifiers(of event: NSEvent) -> KeySpec.Modifiers {
        var modifiers = KeySpec.Modifiers()
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    private static func scriptName(_ key: SpecialKey) -> String? {
        switch key {
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .home: return "home"
        case .end: return "end"
        case .pageUp: return "pageup"
        case .pageDown: return "pagedown"
        case .deleteForward: return "delete"
        case .escape: return "escape"
        case .enter, .keypadEnter: return "enter"
        case .tab: return "tab"
        case .backspace: return "backspace"
        case .f1: return "f1"
        case .f2: return "f2"
        case .f3: return "f3"
        case .f4: return "f4"
        case .f5: return "f5"
        case .f6: return "f6"
        case .f7: return "f7"
        case .f8: return "f8"
        case .f9: return "f9"
        case .f10: return "f10"
        case .f11: return "f11"
        case .f12: return "f12"
        default: return nil
        }
    }

    /// US unshifted key plus the W3C `KeyboardEvent.code`. Control characters are not the key name.
    private static let usKeys: [UInt16: (key: String, code: String)] = {
        var map: [UInt16: (key: String, code: String)] = [:]
        let letters: [(UInt16, Character)] = [
            (0x00, "a"), (0x0B, "b"), (0x08, "c"), (0x02, "d"), (0x0E, "e"), (0x03, "f"),
            (0x05, "g"), (0x04, "h"), (0x22, "i"), (0x26, "j"), (0x28, "k"), (0x25, "l"),
            (0x2E, "m"), (0x2D, "n"), (0x1F, "o"), (0x23, "p"), (0x0C, "q"), (0x0F, "r"),
            (0x01, "s"), (0x11, "t"), (0x20, "u"), (0x09, "v"), (0x0D, "w"), (0x07, "x"),
            (0x10, "y"), (0x06, "z"),
        ]
        for (code, letter) in letters {
            map[code] = (String(letter), "Key\(String(letter).uppercased())")
        }
        let digits: [(UInt16, Character)] = [
            (0x1D, "0"), (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"),
            (0x17, "5"), (0x16, "6"), (0x1A, "7"), (0x1C, "8"), (0x19, "9"),
        ]
        for (code, digit) in digits {
            map[code] = (String(digit), "Digit\(digit)")
        }
        let symbols: [(UInt16, String, String)] = [
            (0x18, "=", "Equal"), (0x1B, "-", "Minus"), (0x1E, "]", "BracketRight"),
            (0x21, "[", "BracketLeft"), (0x27, "'", "Quote"), (0x29, ";", "Semicolon"),
            (0x2A, "\\", "Backslash"), (0x2B, ",", "Comma"), (0x2C, "/", "Slash"),
            (0x2F, ".", "Period"), (0x32, "`", "Backquote"),
        ]
        for (code, key, name) in symbols { map[code] = (key, name) }
        let named: [(UInt16, String, String)] = [
            (0x24, "enter", "Enter"), (0x4C, "enter", "NumpadEnter"), (0x30, "tab", "Tab"),
            (0x31, "space", "Space"), (0x33, "backspace", "Backspace"), (0x35, "escape", "Escape"),
            (0x75, "delete", "Delete"), (0x7E, "up", "ArrowUp"), (0x7D, "down", "ArrowDown"),
            (0x7B, "left", "ArrowLeft"), (0x7C, "right", "ArrowRight"), (0x73, "home", "Home"),
            (0x77, "end", "End"), (0x74, "pageup", "PageUp"), (0x79, "pagedown", "PageDown"),
            (0x7A, "f1", "F1"), (0x78, "f2", "F2"), (0x63, "f3", "F3"), (0x76, "f4", "F4"),
            (0x60, "f5", "F5"), (0x61, "f6", "F6"), (0x62, "f7", "F7"), (0x64, "f8", "F8"),
            (0x65, "f9", "F9"), (0x6D, "f10", "F10"), (0x67, "f11", "F11"), (0x6F, "f12", "F12"),
        ]
        for (code, key, name) in named { map[code] = (key, name) }
        return map
    }()
}
