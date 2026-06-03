import XCTest
@testable import HarnessCore

final class TerminalIdentityTests: XCTestCase {
    func testDefaultsToCompatibleGhostty() {
        // The reported bug (#39) is fixed by reporting a recognized identity by default.
        XCTAssertEqual(TerminalIdentity.mode(nil), .compatible)
        XCTAssertEqual(TerminalIdentity.mode(""), .compatible)
        XCTAssertEqual(TerminalIdentity.mode("nonsense"), .compatible)
        let spec = TerminalIdentity.spec(forOption: nil)
        XCTAssertEqual(spec.name, "ghostty")
        XCTAssertEqual(spec.version, HarnessVersion.short)
        XCTAssertEqual(spec.daVersion, HarnessVersion.build)
    }

    func testStrictReportsHarness() {
        XCTAssertEqual(TerminalIdentity.mode("harness"), .harness)
        XCTAssertEqual(TerminalIdentity.mode("Harness"), .harness) // case-insensitive
        let spec = TerminalIdentity.spec(forOption: "harness")
        XCTAssertEqual(spec.name, "Harness")
        XCTAssertEqual(spec.version, HarnessVersion.short)
    }

    func testOptionStoreShipsCompatibleDefault() {
        // The daemon + app both read this key from options.json; the shipped default must be
        // `compatible` so a fresh install fixes Shift+Enter without any user action.
        let value = OptionStore.builtinDefaults[TerminalIdentity.optionKey]
        XCTAssertEqual(value?.stringValue, TerminalIdentity.Mode.compatible.rawValue)
    }
}
