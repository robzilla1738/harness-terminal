import AppKit
import Foundation
import XCTest
@testable import HarnessApp
import HarnessCore

/// The root-table caps-lock fallback: an uppercase letter typed WITHOUT Shift (caps lock) must
/// reach the lowercase `bind -n` binding, while Shift+letter stays distinct so a typed `C`
/// headed for the shell is never swallowed when only `bind -n c` exists.
@MainActor
final class PrefixKeymapFallbackTests: XCTestCase {
    func testCapsLockUppercaseFallsBackToLowercase() {
        let fallback = PrefixKeymap.capsLockRootFallback(
            spec: KeySpec(key: "C", modifiers: []), shiftPressed: false)
        XCTAssertEqual(fallback, KeySpec(key: "c", modifiers: []))
    }

    func testShiftedUppercaseStaysDistinct() {
        XCTAssertNil(PrefixKeymap.capsLockRootFallback(
            spec: KeySpec(key: "C", modifiers: []), shiftPressed: true))
    }

    func testLowercaseAndNamedKeysHaveNoFallback() {
        XCTAssertNil(PrefixKeymap.capsLockRootFallback(
            spec: KeySpec(key: "c", modifiers: []), shiftPressed: false))
        XCTAssertNil(PrefixKeymap.capsLockRootFallback(
            spec: KeySpec(key: "Escape", modifiers: []), shiftPressed: false))
    }

    /// The default prefix table binds `Space` (next-layout), so the space bar must name it.
    func testSpaceBarIsTheSpaceKey() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 0x31
        ))
        XCTAssertEqual(PrefixKeymap.makeSpec(from: event), KeySpec(key: "Space"))
    }

    func testModifiersAreCarriedThrough() {
        let fallback = PrefixKeymap.capsLockRootFallback(
            spec: KeySpec(key: "P", modifiers: [.control]), shiftPressed: false)
        XCTAssertEqual(fallback, KeySpec(key: "p", modifiers: [.control]))
    }
}
