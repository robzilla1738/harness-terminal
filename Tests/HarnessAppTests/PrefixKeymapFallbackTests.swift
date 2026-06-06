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

    func testModifiersAreCarriedThrough() {
        let fallback = PrefixKeymap.capsLockRootFallback(
            spec: KeySpec(key: "P", modifiers: [.control]), shiftPressed: false)
        XCTAssertEqual(fallback, KeySpec(key: "p", modifiers: [.control]))
    }
}
