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
        // The scroll hint rides along, but every row was freshly written this window
        // (a, b, c all shifted into place this consume), so nothing is shift-reusable.
        XCTAssertEqual(d.scroll, -1)
        XCTAssertTrue(d.scrolledRows.isEmpty)
    }

    // MARK: - Whole-viewport scroll hint

    func testStreamingScrollReportsShiftReusableRows() {
        let t = term(10, 6)
        t.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf")  // fill the screen, cursor on the bottom row
        _ = t.consumeDamage()
        t.feed("\r\ng\r\nh")                  // two new lines -> two whole-viewport scrolls
        let d = t.consumeDamage()
        XCTAssertFalse(d.full)
        XCTAssertEqual(d.scroll, -2)
        // Hint-unaware consumers still see the whole viewport dirty (the moved band included).
        XCTAssertEqual(d.rows, IndexSet(integersIn: 0 ..< 6))
        // The moved-but-unchanged top band is shift-reusable; the written/blank bottom rows and
        // the cursor's old row are fresh. Reusable rows map to `row - scroll` in the prior frame.
        XCTAssertFalse(d.scrolledRows.isEmpty)
        for r in d.scrolledRows {
            XCTAssertTrue(d.rows.contains(r), "scrolledRows must be a subset of rows")
            XCTAssertTrue((0 ..< 6).contains(r - d.scroll), "source row must have existed")
        }
        XCTAssertFalse(d.scrolledRows.contains(5), "the written bottom row is fresh, not moved")
    }

    func testWriteAfterScrollIsFreshNotShiftReusable() {
        let t = term(10, 4)
        t.feed("a\r\nb\r\nc\r\nd")
        _ = t.consumeDamage()
        t.feed("\r\ne\u{1b}[1;1Hx")           // scroll once, then overwrite the TOP row
        let d = t.consumeDamage()
        XCTAssertEqual(d.scroll, -1)
        XCTAssertFalse(d.scrolledRows.contains(0), "an overwritten moved row must re-resolve")
        XCTAssertTrue(d.rows.contains(0))
    }

    func testWriteBeforeScrollShiftsWithTheContent() {
        let t = term(10, 4)
        t.feed("a\r\nb\r\nc\r\nd")
        _ = t.consumeDamage()
        t.feed("\u{1b}[2;1HX")                // dirty row 1 (its content: 'X')
        t.feed("\u{1b}[4;1H\r\ne")            // then scroll: 'X' now lives on row 0
        let d = t.consumeDamage()
        XCTAssertEqual(d.scroll, -1)
        XCTAssertTrue(d.rows.contains(0), "the pre-scroll mark must move with its content")
        XCTAssertFalse(d.scrolledRows.contains(0), "the moved fresh row still re-resolves")
    }

    func testSubRegionScrollWithholdsHint() {
        let t = term(10, 6)
        t.feed("a\r\nb\r\nc\r\nd\r\ne\r\nf")
        _ = t.consumeDamage()
        t.feed("\u{1b}[2;4r")                 // DECSTBM: region rows 1-3 (0-based)
        t.feed("\u{1b}[4;1H\r\n")             // scroll within the sub-region
        t.feed("\u{1b}[r")                    // reset region (cursor homes; no content change)
        let d = t.consumeDamage()
        XCTAssertEqual(d.scroll, 0, "sub-region scrolls cannot be described by the hint")
        XCTAssertTrue(d.scrolledRows.isEmpty)
        XCTAssertTrue(d.rows.contains(integersIn: 1 ... 3), "the scrolled region is dirty")
    }

    func testMixedWholeAndSubRegionScrollDegradesToAllDirty() {
        let t = term(10, 4)
        t.feed("a\r\nb\r\nc\r\nd")
        _ = t.consumeDamage()
        t.feed("\r\ne")                       // whole-viewport scroll (hint pending)
        t.feed("\u{1b}[1;2r\u{1b}[2;1H\r\n\u{1b}[r") // then a sub-region scroll -> poison
        let d = t.consumeDamage()
        XCTAssertEqual(d.scroll, 0)
        XCTAssertTrue(d.scrolledRows.isEmpty)
        XCTAssertEqual(d.rows, IndexSet(integersIn: 0 ..< 4),
                       "a poisoned hint leaves the whole viewport dirty (pre-hint behavior)")
    }

    func testScrollCoveringTheViewportDegrades() {
        let t = term(10, 3)
        t.feed("a\r\nb\r\nc")
        _ = t.consumeDamage()
        t.feed("\u{1b}[3S")                   // SU by the full region height: nothing survives
        let d = t.consumeDamage()
        XCTAssertEqual(d.scroll, 0, "a shift covering the grid has no reusable band")
        XCTAssertTrue(d.scrolledRows.isEmpty)
        XCTAssertEqual(d.rows, IndexSet(integersIn: 0 ..< 3))
    }

    func testFullDamageSuppressesHint() {
        let t = term(10, 3)
        t.feed("a\r\nb\r\nc")
        _ = t.consumeDamage()
        t.feed("\r\nd")                       // whole-viewport scroll (hint pending)
        t.feed("\u{1b}[2J")                   // then ED 2 -> full
        let d = t.consumeDamage()
        XCTAssertTrue(d.full)
        XCTAssertEqual(d.scroll, 0)
        XCTAssertTrue(d.scrolledRows.isEmpty)
    }

    func testOppositeScrollsCancelArithmetically() {
        let t = term(10, 4)
        t.feed("a\r\nb\r\nc\r\nd")
        _ = t.consumeDamage()
        t.feed("\u{1b}[1S\u{1b}[1T")          // SU 1 then SD 1: middle rows return to position
        let d = t.consumeDamage()
        XCTAssertEqual(d.scroll, 0, "a net-zero shift is no hint")
        XCTAssertTrue(d.scrolledRows.isEmpty)
        // Rows whose content genuinely changed (the blanked top, and the bottom row the SU
        // blanked before SD discarded it) are dirty; returned-to-place rows need not be.
        XCTAssertTrue(d.rows.contains(0), "SD's blanked top row is dirty")
    }

    func testHintResetsAcrossConsumes() {
        let t = term(10, 4)
        t.feed("a\r\nb\r\nc\r\nd")
        _ = t.consumeDamage()
        t.feed("\r\ne")
        XCTAssertEqual(t.consumeDamage().scroll, -1)
        let d = t.consumeDamage()             // nothing since
        XCTAssertEqual(d.scroll, 0)
        XCTAssertTrue(d.scrolledRows.isEmpty)
        XCTAssertTrue(d.rows.isEmpty)
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
