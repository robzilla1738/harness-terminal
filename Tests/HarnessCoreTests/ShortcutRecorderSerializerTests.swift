import XCTest
@testable import HarnessCore

final class ShortcutRecorderSerializerTests: XCTestCase {
    func testRecordsControlLetterFromC0Byte() {
        XCTAssertEqual(
            ShortcutRecorderSerializer.serialize(raw: "\u{01}", modifiers: .control),
            "ctrl-a"
        )
        XCTAssertEqual(
            ShortcutRecorderSerializer.serialize(raw: "\u{02}", modifiers: .control),
            "ctrl-b"
        )
    }

    func testRecordsControlLetterFromIgnoringModifiersCharacter() {
        XCTAssertEqual(
            ShortcutRecorderSerializer.serialize(raw: "a", modifiers: .control),
            "ctrl-a"
        )
    }

    func testRecordsShiftPrintableShortcuts() {
        XCTAssertEqual(
            ShortcutRecorderSerializer.serialize(raw: "p", modifiers: [.command, .shift]),
            "shift-cmd-p"
        )
    }

    func testRecordsSpecialKeys() {
        XCTAssertEqual(ShortcutRecorderSerializer.serialize(raw: "\u{09}", modifiers: .shift), "shift-tab")
        XCTAssertEqual(ShortcutRecorderSerializer.serialize(raw: "\u{F700}", modifiers: .control), "ctrl-up")
        XCTAssertEqual(ShortcutRecorderSerializer.serialize(raw: "\u{F704}", modifiers: []), "f1")
    }

    func testGlyphStringMatchesSerializedShortcut() {
        XCTAssertEqual(ShortcutRecorderSerializer.glyphString(for: "ctrl-a"), "⌃A")
        XCTAssertEqual(ShortcutRecorderSerializer.glyphString(for: "shift-cmd-p"), "⇧⌘P")
    }

    func testNamedKeysRoundTripFromKeyCode() {
        let cases: [(UInt16, String)] = [
            (126, "up"), (125, "down"), (123, "left"), (124, "right"), (49, "space"),
            (36, "enter"), (76, "enter"), (48, "tab"), (53, "escape"), (51, "backspace"),
            (117, "forwarddelete"), (115, "home"), (119, "end"), (116, "pageup"), (121, "pagedown"),
            (122, "f1"), (96, "f5"), (111, "f12"), (105, "f13"), (90, "f20"),
        ]
        for (code, name) in cases {
            let raw = ShortcutRecorderSerializer.serialize(keyCode: code, raw: "?", modifiers: [.control, .option])
            XCTAssertEqual(raw, "ctrl-opt-\(name)")
            XCTAssertEqual(ShortcutRecorderSerializer.namedKey(forKeyCode: code), name)
            XCTAssertEqual(raw.flatMap(ShortcutRecorderSerializer.parse),
                           KeySpec(key: name, modifiers: [.control, .option]))
        }
    }

    func testKeyCodeWinsOverControlMangledCharacters() {
        // Ctrl-Tab's characters are \t, which control-normalization would read as `i`.
        XCTAssertEqual(ShortcutRecorderSerializer.serialize(keyCode: 48, raw: "\t", modifiers: .control), "ctrl-tab")
        XCTAssertEqual(ShortcutRecorderSerializer.serialize(keyCode: 0, raw: "a", modifiers: .control), "ctrl-a")
    }

    func testPunctuationKeysRoundTrip() {
        for key in ["-", "+", "=", ",", "/"] {
            let raw = ShortcutRecorderSerializer.serialize(raw: key, modifiers: .command)
            XCTAssertEqual(raw, "cmd-\(key)")
            XCTAssertEqual(raw.flatMap(ShortcutRecorderSerializer.parse), KeySpec(key: key, modifiers: .command))
        }
        XCTAssertEqual(ShortcutRecorderSerializer.parse("ctrl-shift--"), KeySpec(key: "-", modifiers: [.control, .shift]))
        XCTAssertEqual(ShortcutRecorderSerializer.parse("-"), KeySpec(key: "-"))
        XCTAssertEqual(ShortcutRecorderSerializer.glyphString(for: "cmd--"), "⌘-")
    }

    func testParseAliasesAndRejectsJunk() {
        XCTAssertEqual(ShortcutRecorderSerializer.parse("CMD-Return"), KeySpec(key: "enter", modifiers: .command))
        XCTAssertEqual(ShortcutRecorderSerializer.parse("opt-esc"), KeySpec(key: "escape", modifiers: .option))
        XCTAssertEqual(ShortcutRecorderSerializer.parse("cmd-delete"), KeySpec(key: "backspace", modifiers: .command))
        XCTAssertEqual(ShortcutRecorderSerializer.parse("ctrl-a"), KeySpec(key: "a", modifiers: .control))
        XCTAssertNil(ShortcutRecorderSerializer.parse("hyper-a"))
        XCTAssertNil(ShortcutRecorderSerializer.parse("cmd-"))
        XCTAssertNil(ShortcutRecorderSerializer.parse("cmd-bogus"))
        XCTAssertNil(ShortcutRecorderSerializer.parse(""))
    }

    func testCharacterNamesForMenuKeyEquivalents() {
        XCTAssertEqual(ShortcutRecorderSerializer.keyName(forCharacters: "\u{F708}"), "f5")
        XCTAssertEqual(ShortcutRecorderSerializer.keyName(forCharacters: "\u{F717}"), "f20")
        XCTAssertEqual(ShortcutRecorderSerializer.keyName(forCharacters: "\u{F728}"), "forwarddelete")
        XCTAssertEqual(ShortcutRecorderSerializer.keyName(forCharacters: "\u{8}"), "backspace")
        XCTAssertEqual(ShortcutRecorderSerializer.keyName(forCharacters: "\r"), "enter")
    }

    func testNamedKeyGlyphs() {
        XCTAssertEqual(ShortcutRecorderSerializer.glyphString(for: "opt-up"), "⌥↑")
        XCTAssertEqual(ShortcutRecorderSerializer.glyphString(for: "ctrl-space"), "⌃Space")
        XCTAssertEqual(ShortcutRecorderSerializer.glyphString(for: "cmd-f5"), "⌘F5")
    }
}
