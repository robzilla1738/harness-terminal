import Foundation
import XCTest
@testable import HarnessTerminalEngine

/// Regression coverage for `VTParser`'s debug-only single-threaded tripwire (`isFeeding`).
///
/// The parser hands the handler borrowed `UnsafeBufferPointer` views that are valid only for the
/// synchronous `feed` call, so a concurrent or reentrant feed would be a use-after-free. A
/// `#if DEBUG assert(!isFeeding)` traps on violations. We can't assert the *trip* here (it aborts
/// the process), so this proves the inverse — the guard does NOT false-trip on any legitimate
/// pattern: repeated sequential feeds across all three public entry points, and the synchronous
/// handler→`respond`→`onResponse` call chain that runs *inside* a feed. If the flag failed to
/// balance (e.g. a missing `defer`), the second feed in any of these would trap and crash the test.
final class VTParserReentrancyGuardTests: XCTestCase {
    func testGuardDoesNotFalseTripAcrossSequentialFeedsOnEveryEntryPoint() {
        let emu = TerminalEmulator(cols: 80, rows: 24)
        emu.feed("abc")                          // feed(_ bytes:) via String -> [UInt8]
        emu.feed(Data("def".utf8))               // feed(_ data:)
        emu.feedScalarwise(Array("ghi".utf8))    // feedScalarwise(_:) — distinct guarded entry
        emu.feed("jkl")                           // back to the array path; flag must be clear
        let grid = emu.readGrid()
        let row0 = (0..<12).compactMap { grid.cell(row: 0, col: $0)?.codepoint }
            .compactMap { UnicodeScalar($0).map(Character.init) }
        XCTAssertEqual(String(row0), "abcdefghijkl",
                       "every public entry point must run to completion and clear the guard")
    }

    func testHandlerResponseCallbackDoesNotTripGuardAndFeedStaysUsable() {
        // A DSR query makes the handler call `respond` -> `onResponse` *synchronously during* the
        // feed. That nested handler dispatch shares the call stack but never re-enters `feed`, so
        // the guard must not trip — and the very next feed must still write normally.
        let emu = TerminalEmulator(cols: 80, rows: 24)
        var response = Data()
        emu.onResponse = { response.append($0) }
        emu.feed("\u{1b}[1;1H\u{1b}[6n")          // home cursor, then Device Status Report
        XCTAssertEqual(String(data: response, encoding: .utf8), "\u{1b}[1;1R",
                       "DSR must reply via the synchronous handler callback")
        emu.feed("Z")                             // guard cleared after the response-bearing feed
        XCTAssertEqual(emu.readGrid().cell(row: 0, col: 0)?.codepoint,
                       UInt32(UnicodeScalar("Z").value),
                       "a feed following a response-generating feed must still apply")
    }
}
