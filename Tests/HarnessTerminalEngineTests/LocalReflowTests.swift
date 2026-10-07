import XCTest
@testable import HarnessTerminalEngine

/// Non-owner resize reflows the primary screen only. The alternate screen does not
/// take that path, and the alternate buffer keeps the size it already had.
final class LocalReflowTests: XCTestCase {
    func testAlternateScreenResizeDoesNotTakeTheLocalReflowPath() {
        let term = TerminalEmulator(cols: 80, rows: 24)
        term.feed("primary")
        term.feed("\u{1b}[?1049h")
        XCTAssertTrue(term.isAlternateScreenActive)
        let before = term.readGrid()
        XCTAssertFalse(term.resizePrimaryLocally(cols: 40, rows: 12))
        let after = term.readGrid()
        XCTAssertEqual(after.cols, before.cols)
        XCTAssertEqual(after.rows, before.rows)
        XCTAssertEqual(after.cells, before.cells)
        XCTAssertEqual(term.cols, 80)
        XCTAssertEqual(term.rows, 24)
    }

    func testPrimaryLocalReflowDoesNotResizeTheAlternateBuffer() {
        let term = TerminalEmulator(cols: 80, rows: 24)
        XCTAssertFalse(term.isAlternateScreenActive)
        XCTAssertTrue(term.resizePrimaryLocally(cols: 40, rows: 12))
        XCTAssertEqual(term.cols, 40)
        XCTAssertEqual(term.rows, 12)

        term.feed("\u{1b}[?1049h")
        XCTAssertTrue(term.isAlternateScreenActive)
        XCTAssertEqual(term.cols, 80)
        XCTAssertEqual(term.rows, 24)
        XCTAssertFalse(term.resizePrimaryLocally(cols: 20, rows: 8))
        XCTAssertEqual(term.cols, 80)
        XCTAssertEqual(term.rows, 24)

        term.feed("\u{1b}[?1049l")
        XCTAssertFalse(term.isAlternateScreenActive)
        XCTAssertEqual(term.cols, 40)
        XCTAssertEqual(term.rows, 12)
    }
}
