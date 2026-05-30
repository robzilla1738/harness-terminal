import XCTest
@testable import HarnessCore

/// `OptionStore.Value` coercion and the shared `statusLineCount` helper that the GUI
/// status bar and the ssh compositor both read to reserve the same number of rows.
final class OptionValueTests: XCTestCase {
    func testValueParsingCoercesBoolsAndInts() {
        XCTAssertEqual(OptionStore.Value(parsing: "on"), .bool(true))
        XCTAssertEqual(OptionStore.Value(parsing: "off"), .bool(false))
        XCTAssertEqual(OptionStore.Value(parsing: "yes"), .bool(true))
        XCTAssertEqual(OptionStore.Value(parsing: "2"), .int(2))
        XCTAssertEqual(OptionStore.Value(parsing: "vi"), .string("vi"))
    }

    func testBoolValueAcceptsStringForms() {
        // The daemon's monitor gate reads `monitor-activity` via `boolValue`; a string
        // `"on"` must read true (the CLI now stores this as `.bool(true)`, but boolValue
        // must stay tolerant of either encoding).
        XCTAssertTrue(OptionStore.Value.string("on").boolValue)
        XCTAssertFalse(OptionStore.Value.string("off").boolValue)
        XCTAssertTrue(OptionStore.Value.bool(true).boolValue)
        XCTAssertFalse(OptionStore.Value.int(0).boolValue)
    }

    func testStatusLineCount() {
        XCTAssertEqual(OptionStore.Value.bool(true).statusLineCount, 1)
        XCTAssertEqual(OptionStore.Value.bool(false).statusLineCount, 0)
        XCTAssertEqual(OptionStore.Value.int(2).statusLineCount, 2)
        XCTAssertEqual(OptionStore.Value.int(5).statusLineCount, 5)
        // Clamped to tmux's 0...5 range.
        XCTAssertEqual(OptionStore.Value.int(9).statusLineCount, 5)
        XCTAssertEqual(OptionStore.Value.int(-1).statusLineCount, 0)
        // String forms (compositor reads option values as strings).
        XCTAssertEqual(OptionStore.Value.string("3").statusLineCount, 3)
        XCTAssertEqual(OptionStore.Value.string("on").statusLineCount, 1)
        XCTAssertEqual(OptionStore.Value.string("off").statusLineCount, 0)
    }

    func testLifecycleAndTimingDefaults() {
        // remain-on-exit defaults on (Harness's safe default — keep the dead leaf).
        XCTAssertEqual(OptionStore.builtinDefaults["remain-on-exit"], .bool(true))
        // repeat-time defaults to tmux's 500ms.
        XCTAssertEqual(OptionStore.builtinDefaults["repeat-time"], .int(500))
        XCTAssertEqual(OptionStore.builtinDefaults["pane-border-status"], .string("off"))
    }
}
