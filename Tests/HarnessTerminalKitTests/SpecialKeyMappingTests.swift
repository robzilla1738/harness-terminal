import AppKit
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
}
