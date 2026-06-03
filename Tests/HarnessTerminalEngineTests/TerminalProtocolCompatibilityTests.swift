import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Harness protocol coverage: OSC 9/777 notifications, OSC 22 cursor shape, programmable tab
/// stops (HTS/TBC/CHT/CBT), and DEC special-graphics charset designation. All headless.
final class TerminalProtocolCompatibilityTests: XCTestCase {
    // MARK: OSC 9 / 777 notifications

    func testOSC9NotificationBodyOnly() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var got: (String?, String)?
        term.onNotification = { got = ($0, $1) }
        term.feed("\u{1b}]9;build finished\u{07}")
        XCTAssertNil(got?.0)
        XCTAssertEqual(got?.1, "build finished")
    }

    func testOSC777NotifyTitleAndBody() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var got: (String?, String)?
        term.onNotification = { got = ($0, $1) }
        term.feed("\u{1b}]777;notify;Build;succeeded\u{1b}\\")
        XCTAssertEqual(got?.0, "Build")
        XCTAssertEqual(got?.1, "succeeded")
    }

    // MARK: OSC 9;4 progress reports (ConEmu)

    func testOSC94IndeterminateProgress() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        var notified = false
        term.onProgress = { reports.append($0) }
        term.onNotification = { _, _ in notified = true }
        term.feed("\u{1b}]9;4;3;0\u{07}")        // BEL terminator, Claude Code style
        term.feed("\u{1b}]9;4;3\u{1b}\\")        // ST terminator, no value
        XCTAssertEqual(reports, [
            TerminalProgressReport(state: .indeterminate, value: 0),
            TerminalProgressReport(state: .indeterminate, value: nil),
        ])
        XCTAssertFalse(notified, "9;4 must never surface as a notification (Ghostty parity)")
    }

    func testOSC94SetRemoveAndClamp() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        term.onProgress = { reports.append($0) }
        term.feed("\u{1b}]9;4;1;50\u{07}")
        term.feed("\u{1b}]9;4;1;250\u{07}")      // out-of-range value clamps to 100
        term.feed("\u{1b}]9;4;2\u{07}")          // error, no value
        term.feed("\u{1b}]9;4;4;30\u{07}")       // paused at 30
        term.feed("\u{1b}]9;4;0;0\u{07}")        // remove
        XCTAssertEqual(reports, [
            TerminalProgressReport(state: .set, value: 50),
            TerminalProgressReport(state: .set, value: 100),
            TerminalProgressReport(state: .error, value: nil),
            TerminalProgressReport(state: .paused, value: 30),
            TerminalProgressReport(state: .remove, value: 0),
        ])
    }

    func testOSC94UnknownStateIsIgnoredNotNotified() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        var notified = false
        term.onProgress = { reports.append($0) }
        term.onNotification = { _, _ in notified = true }
        term.feed("\u{1b}]9;4;9;0\u{07}")        // state 9 doesn't exist
        XCTAssertTrue(reports.isEmpty)
        XCTAssertFalse(notified)
    }

    func testOSC9BodyStartingWithFourStillNotifiesUnlessSubCodeFour() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var reports: [TerminalProgressReport] = []
        var bodies: [String] = []
        term.onProgress = { reports.append($0) }
        term.onNotification = { bodies.append($1) }
        term.feed("\u{1b}]9;42 tests passed\u{07}") // "42…" is a body, not sub-code 4
        term.feed("\u{1b}]9;hello\u{07}")
        XCTAssertTrue(reports.isEmpty)
        XCTAssertEqual(bodies, ["42 tests passed", "hello"])
    }

    // MARK: OSC 22 pointer shape

    func testOSC22SetsPointerShape() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        var changes: [String?] = []
        term.onPointerShapeChange = { changes.append($0) }
        term.feed("\u{1b}]22;pointer\u{07}")
        XCTAssertEqual(term.pointerShape, "pointer")
        XCTAssertEqual(changes, ["pointer"])
        // Re-setting the same shape doesn't re-fire.
        term.feed("\u{1b}]22;pointer\u{07}")
        XCTAssertEqual(changes, ["pointer"])
    }

    // MARK: Programmable tab stops

    private func cursorCol(_ term: TerminalEmulator) -> Int { term.readGrid().cursor.col }

    func testHTSSetsStopAndTabLandsThere() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\u{1b}[3g")     // TBC clear all stops
        term.feed("\u{1b}[4G")     // CHA → column 4 (1-based) = col 3
        term.feed("\u{1b}H")       // HTS — set a stop here (col 3)
        term.feed("\r\t")          // CR home, then HT
        XCTAssertEqual(cursorCol(term), 3)
    }

    func testTBCClearAllSendsTabToLastColumn() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\u{1b}[3g\r\t") // no stops → tab goes to the last column
        XCTAssertEqual(cursorCol(term), 39)
    }

    func testDefaultTabIsEveryEight() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\r\t")
        XCTAssertEqual(cursorCol(term), 8)
        term.feed("\t")
        XCTAssertEqual(cursorCol(term), 16)
    }

    func testForwardAndBackwardTabs() {
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.feed("\r\u{1b}[3I")   // CHT 3 → cols 8,16,24
        XCTAssertEqual(cursorCol(term), 24)
        term.feed("\u{1b}[2Z")     // CBT 2 → back to col 8
        XCTAssertEqual(cursorCol(term), 8)
    }

    // MARK: DEC special-graphics charset

    private func codepoint(_ term: TerminalEmulator, row: Int, col: Int) -> UInt32? {
        term.readGrid().cell(row: row, col: col)?.codepoint
    }

    func testDECSpecialGraphicsLineDrawing() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}(0lqk")   // designate G0 = special graphics, print l q k
        XCTAssertEqual(codepoint(term, row: 0, col: 0), 0x250C) // ┌
        XCTAssertEqual(codepoint(term, row: 0, col: 1), 0x2500) // ─
        XCTAssertEqual(codepoint(term, row: 0, col: 2), 0x2510) // ┐
    }

    func testCharsetRestoreToASCII() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b}(0q")     // ─
        term.feed("\u{1b}(Bq")     // back to ASCII → literal 'q'
        XCTAssertEqual(codepoint(term, row: 0, col: 0), 0x2500)
        XCTAssertEqual(codepoint(term, row: 0, col: 1), UInt32(UnicodeScalar("q").value))
    }

    func testSOSIInvokeG1AndG0() {
        let term = TerminalEmulator(cols: 20, rows: 4)
        term.feed("\u{1b})0")      // designate G1 = special graphics
        term.feed("\u{0e}q")       // SO → invoke G1, print q → ─
        term.feed("\u{0f}q")       // SI → invoke G0 (ascii), print q → 'q'
        XCTAssertEqual(codepoint(term, row: 0, col: 0), 0x2500)
        XCTAssertEqual(codepoint(term, row: 0, col: 1), UInt32(UnicodeScalar("q").value))
    }
}
