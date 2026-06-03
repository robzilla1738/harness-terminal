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
}
