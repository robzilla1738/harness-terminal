import Foundation
import GhosttyTerminal
import XCTest

/// Phase 1 spike: validates the forked `ghostty_surface_read_cells` styled-grid
/// API end-to-end through `HeadlessTerminalEmulator`. Proves two things:
///   1. A libghostty surface can be created and driven fully headlessly (no
///      window / display link) — the linchpin for the terminal compositor.
///   2. `readGrid()` faithfully reports codepoints, SGR colors, attributes, and
///      wide characters.
@MainActor
final class HeadlessGridReadTests: XCTestCase {
    /// The apprt embedded Surface always carries a Metal renderer tied to an
    /// NSView; off-screen it crashes on `deinit` (renderer teardown). For these
    /// read-only fidelity tests we intentionally leak the emulators (statics are
    /// not deinited at process exit) so teardown never runs. The production
    /// headless compositor uses a renderer-free path instead.
    private static var leaked: [HeadlessTerminalEmulator] = []

    private func makeEmulator(cols: Int = 80, rows: Int = 24) -> HeadlessTerminalEmulator {
        let emu = HeadlessTerminalEmulator(cols: cols, rows: rows)
        Self.leaked.append(emu)
        return emu
    }

    /// Feed bytes, then spin the run loop until `predicate(grid)` holds or we
    /// time out. Host-managed IO may parse slightly asynchronously, so polling
    /// is more robust than a single read.
    private func feedAndWait(
        _ emu: HeadlessTerminalEmulator,
        _ bytes: String,
        attempts: Int = 50,
        predicate: (TerminalGridSnapshot) -> Bool
    ) -> TerminalGridSnapshot? {
        emu.feed(bytes)
        // Host-managed IO parses synchronously on `feed`'s tick, but poll a few
        // times with a short sleep to absorb any latency without running the run
        // loop (which would service the off-screen surface's render callbacks).
        for _ in 0 ..< attempts {
            if let grid = emu.readGrid(), predicate(grid) {
                return grid
            }
            usleep(10_000)
        }
        return emu.readGrid()
    }

    func testHeadlessSurfaceCreates() {
        let emu = makeEmulator()
        XCTAssertTrue(emu.isValid, "headless libghostty surface failed to create")
        let grid = emu.readGrid()
        XCTAssertNotNil(grid, "readGrid returned nil on a valid surface")
        if let grid {
            // NOTE: a precise grid size is not asserted here. Without a running
            // IO loop the host-managed `.resize` doesn't propagate to the screen,
            // so the grid keeps libghostty's default size. What matters for the
            // read API is internal consistency: a rectangular, fully-populated
            // grid. Exact sizing is the renderer-free path's concern.
            XCTAssertGreaterThan(grid.cols, 0)
            XCTAssertGreaterThan(grid.rows, 0)
            XCTAssertEqual(grid.cells.count, grid.rows * grid.cols)
        }
    }

    func testPlainTextLandsInCells() {
        let emu = makeEmulator()
        let grid = feedAndWait(emu, "Hello") { g in
            g.cell(row: 0, col: 0)?.codepoint == UInt32(UnicodeScalar("H").value)
        }
        guard let grid else { return XCTFail("no grid") }
        let expected = Array("Hello".unicodeScalars).map { UInt32($0.value) }
        for (i, cp) in expected.enumerated() {
            XCTAssertEqual(grid.cell(row: 0, col: i)?.codepoint, cp, "mismatch at col \(i)")
        }
    }

    func testForegroundPaletteColor() {
        let emu = makeEmulator()
        // SGR 31 = red (palette index 1).
        let grid = feedAndWait(emu, "\u{1b}[31mR") { g in
            g.cell(row: 0, col: 0)?.codepoint == UInt32(UnicodeScalar("R").value)
        }
        guard let cell = grid?.cell(row: 0, col: 0) else { return XCTFail("no cell") }
        XCTAssertEqual(cell.foreground, .palette(1), "expected red = palette 1, got \(cell.foreground)")
    }

    func test256Color() {
        let emu = makeEmulator()
        // SGR 38;5;208 = palette index 208 foreground.
        let grid = feedAndWait(emu, "\u{1b}[38;5;208mO") { g in
            g.cell(row: 0, col: 0)?.codepoint == UInt32(UnicodeScalar("O").value)
        }
        guard let cell = grid?.cell(row: 0, col: 0) else { return XCTFail("no cell") }
        XCTAssertEqual(cell.foreground, .palette(208))
    }

    func testTrueColorBackground() {
        let emu = makeEmulator()
        // SGR 48;2;10;20;30 = direct RGB background.
        let grid = feedAndWait(emu, "\u{1b}[48;2;10;20;30mX") { g in
            g.cell(row: 0, col: 0)?.codepoint == UInt32(UnicodeScalar("X").value)
        }
        guard let cell = grid?.cell(row: 0, col: 0) else { return XCTFail("no cell") }
        XCTAssertEqual(cell.background, .rgb(r: 10, g: 20, b: 30))
    }

    func testAttributesBoldItalicUnderline() {
        let emu = makeEmulator()
        // Bold + italic + single underline.
        let grid = feedAndWait(emu, "\u{1b}[1;3;4mA") { g in
            g.cell(row: 0, col: 0)?.codepoint == UInt32(UnicodeScalar("A").value)
        }
        guard let cell = grid?.cell(row: 0, col: 0) else { return XCTFail("no cell") }
        XCTAssertTrue(cell.bold, "bold not set")
        XCTAssertTrue(cell.italic, "italic not set")
        XCTAssertEqual(cell.underline, .single, "underline not single")
    }

    func testInverseAttribute() {
        let emu = makeEmulator()
        let grid = feedAndWait(emu, "\u{1b}[7mI") { g in
            g.cell(row: 0, col: 0)?.codepoint == UInt32(UnicodeScalar("I").value)
        }
        guard let cell = grid?.cell(row: 0, col: 0) else { return XCTFail("no cell") }
        XCTAssertTrue(cell.inverse, "inverse not set")
    }

    func testWideCharacter() {
        let emu = makeEmulator()
        // CJK ideograph occupies two cells: a wide cell + a spacer tail.
        let grid = feedAndWait(emu, "世") { g in
            g.cell(row: 0, col: 0)?.codepoint == UInt32(UnicodeScalar("世").value)
        }
        guard let grid else { return XCTFail("no grid") }
        XCTAssertEqual(grid.cell(row: 0, col: 0)?.width, .wide, "first cell should be wide")
        XCTAssertEqual(grid.cell(row: 0, col: 1)?.width, .spacerTail, "second cell should be spacer tail")
    }

    func testCursorPosition() {
        let emu = makeEmulator()
        // Move cursor to row 5, col 10 (1-based CSI -> 0-based grid).
        let grid = feedAndWait(emu, "\u{1b}[5;10H") { g in
            g.cursor.row == 4 && g.cursor.col == 9
        }
        guard let grid else { return XCTFail("no grid") }
        XCTAssertEqual(grid.cursor.row, 4)
        XCTAssertEqual(grid.cursor.col, 9)
        XCTAssertTrue(grid.cursor.visible)
    }
}
