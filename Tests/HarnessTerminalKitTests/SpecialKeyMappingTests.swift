import AppKit
import HarnessTerminalEngine
import XCTest
@testable import HarnessTerminalKit

/// The NSEvent → SpecialKey seam. The regression of record: macOS delivers Shift+Tab as
/// NSBackTabCharacter (0x19), not 0x09, so the mapper must recognize both — otherwise Shift+Tab
/// never reaches the encoder (→ ESC[Z) and AppKit silently swallows it as `insertBacktab:`.
@MainActor
final class SpecialKeyMappingTests: XCTestCase {
    private func keyEvent(charactersIgnoringModifiers: String, shift: Bool, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: shift ? .shift : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: charactersIgnoringModifiers,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func testPlainTabMapsToTab() {
        let event = keyEvent(charactersIgnoringModifiers: "\u{09}", shift: false, keyCode: 48)
        XCTAssertEqual(HarnessTerminalSurfaceView.specialKey(for: event), .tab)
    }

    func testShiftTabBackTabCharacterMapsToTab() {
        // The fix: 0x19 (NSBackTabCharacter) must map to .tab so Shift+Tab encodes ESC[Z.
        let event = keyEvent(charactersIgnoringModifiers: "\u{19}", shift: true, keyCode: 48)
        XCTAssertEqual(HarnessTerminalSurfaceView.specialKey(for: event), .tab)
    }

    // MARK: Numeric keypad (F30 follow-up: modified combos)

    private func keypadEvent(_ character: String, flags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags.union(.numericPad),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode // 87 = kVK_ANSI_Keypad5
        )!
    }

    func testUnmodifiedKeypadKeyMapsToKeypadSpecialKey() {
        XCTAssertEqual(
            HarnessTerminalSurfaceView.specialKey(for: keypadEvent("5", flags: [], keyCode: 87)),
            .keypad5
        )
        // Shift doesn't block the claim (NumLock-style modifiers are fine).
        XCTAssertEqual(
            HarnessTerminalSurfaceView.specialKey(for: keypadEvent("5", flags: .shift, keyCode: 87)),
            .keypad5
        )
    }

    /// Ctrl/Option/⌘-modified keypad keys must NOT be claimed as SpecialKeys: `keypadLegacy`
    /// ignores modifiers, so claiming them would drop the control collapse / ESC meta prefix
    /// the text path applies. They fall through and keep the pre-keypad byte output, in both
    /// numeric and application keypad modes (the text path ignores DECKPAM).
    func testModifiedKeypadKeysFallThroughToTheTextPath() {
        for flags in [NSEvent.ModifierFlags.control, .option, .command] {
            XCTAssertNil(
                HarnessTerminalSurfaceView.specialKey(for: keypadEvent("5", flags: flags, keyCode: 87)),
                "modified keypad keys must not be claimed (\(flags.rawValue))"
            )
        }
        // Pin the text-path bytes the fall-through reaches — the pre-keypad output.
        let encoder = InputEncoder()
        var application = TerminalModes()
        application.keypadApplication = true
        for modes in [TerminalModes(), application] {
            XCTAssertEqual(
                encoder.encode(text: "5", shifted: "5", modifiers: [.control], event: .press,
                               associatedText: "5", modes: modes),
                [0x35], "Ctrl+KP5: digits have no C0 collapse — the plain byte"
            )
            XCTAssertEqual(
                encoder.encode(text: "5", shifted: "5", modifiers: [.option], event: .press,
                               associatedText: "5", modes: modes),
                [0x1B, 0x35], "Option+KP5: ESC meta prefix"
            )
        }
    }
}
