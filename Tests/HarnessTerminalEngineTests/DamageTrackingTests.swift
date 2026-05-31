import Foundation
import XCTest
import HarnessTerminalEngine

/// Dirty-row damage tracking: `TerminalEmulator.consumeDamage()` must report exactly the rows
/// that changed since the last call, flag screen-wide changes as `full`, and flag pure cursor
/// moves as `cursorOnly` (with both the old and new cursor rows present).
final class DamageTrackingTests: XCTestCase {
    private func term(_ cols: Int = 10, _ rows: Int = 5) -> TerminalEmulator {
        TerminalEmulator(cols: cols, rows: rows)
    }

    /// `IndexSet` has no array-literal initializer; build one from explicit rows.
    private func rowSet(_ values: Int...) -> IndexSet {
        var s = IndexSet()
        for v in values { s.insert(v) }
        return s
    }

    func testInitialDamageIsFull() {
        // The first render must paint everything.
        XCTAssertTrue(term().consumeDamage().full)
    }

    func testConsumeResetsToEmpty() {
        let t = term()
        _ = t.consumeDamage()                 // clear the initial full
        let d = t.consumeDamage()             // nothing happened since
        XCTAssertFalse(d.full)
        XCTAssertFalse(d.cursorOnly)
        XCTAssertTrue(d.rows.isEmpty)
    }

    func testPrintMarksOnlyTheCursorRow() {
        let t = term()
        _ = t.consumeDamage()
        t.feed("hello")                       // stays on row 0
        let d = t.consumeDamage()
        XCTAssertFalse(d.full)
        XCTAssertFalse(d.cursorOnly)
        XCTAssertEqual(d.rows, IndexSet(integer: 0))
    }

    func testPrintOnLaterRowMarksThatRow() {
        let t = term()
        t.feed("\u{1b}[3;1Hx")                // CUP to row 2 (1-based 3), print
        _ = t.consumeDamage()                 // includes the move + the write
        t.feed("y")                           // another char on row 2, cursor stays
        let d = t.consumeDamage()
        XCTAssertEqual(d.rows, IndexSet(integer: 2))
        XCTAssertFalse(d.cursorOnly)
    }

    func testNewlineReportsOldAndNewCursorRows() {
        let t = term()
        _ = t.consumeDamage()
        t.feed("\r\n")                        // row 0 -> 1, no content
        let d = t.consumeDamage()
        XCTAssertFalse(d.full)
        XCTAssertTrue(d.cursorOnly)
        XCTAssertEqual(d.rows, rowSet(0, 1))
    }

    func testCursorPositionMoveIsCursorOnly() {
        let t = term()
        _ = t.consumeDamage()
        t.feed("\u{1b}[3;5H")                 // CUP to row 2
        let d = t.consumeDamage()
        XCTAssertTrue(d.cursorOnly)
        XCTAssertEqual(d.rows, rowSet(0, 2))
    }

    func testEraseInLineMarksOneRow() {
        let t = term()
        t.feed("\u{1b}[3;1Habc")              // content on row 2
        _ = t.consumeDamage()
        t.feed("\u{1b}[2K")                   // erase line (cursor still row 2)
        let d = t.consumeDamage()
        XCTAssertFalse(d.full)
        XCTAssertEqual(d.rows, IndexSet(integer: 2))
    }

    func testEraseInDisplayAllIsFull() {
        let t = term()
        _ = t.consumeDamage()
        t.feed("\u{1b}[2J")
        XCTAssertTrue(t.consumeDamage().full)
    }

    func testScrollMarksTheWholeRegion() {
        let t = term(5, 3)
        _ = t.consumeDamage()
        t.feed("a\r\nb\r\nc\r\nd")            // 4th line scrolls the 3-row screen
        let d = t.consumeDamage()
        XCTAssertFalse(d.full)
        XCTAssertEqual(d.rows, IndexSet(integersIn: 0 ..< 3))
    }

    func testResizeIsFull() {
        let t = term()
        _ = t.consumeDamage()
        t.resize(cols: 20, rows: 8)
        XCTAssertTrue(t.consumeDamage().full)
    }

    func testFullResetIsFull() {
        let t = term()
        _ = t.consumeDamage()
        t.feed("\u{1b}c")                     // RIS
        XCTAssertTrue(t.consumeDamage().full)
    }

    func testAlternateScreenSwitchIsFull() {
        let t = term()
        _ = t.consumeDamage()
        t.feed("\u{1b}[?1049h")               // enter alternate screen
        XCTAssertTrue(t.consumeDamage().full)
        t.feed("\u{1b}[?1049l")               // leave it
        XCTAssertTrue(t.consumeDamage().full)
    }
}
