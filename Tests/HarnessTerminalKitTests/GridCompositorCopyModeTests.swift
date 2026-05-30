import Foundation
import HarnessCopyMode
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessTerminalKit
import XCTest

/// The compositor's copy-mode overlay: selection / search shading (palette-based so the
/// client terminal themes them) and the copy-mode cursor placement.
final class GridCompositorCopyModeTests: XCTestCase {
    private func snapshot(_ cols: Int, _ rows: Int, _ bytes: String) -> TerminalGridSnapshot {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(bytes)
        return term.readGrid()!
    }

    private func rect(_ cols: Int, _ rows: Int) -> PaneRect {
        PaneRect(paneID: UUID(), surfaceID: UUID(), x: 0, y: 0, cols: cols, rows: rows)
    }

    func testSelectionShadingEmitsPaletteBackground() {
        let comp = GridCompositor(cols: 20, rows: 6)
        let grid = snapshot(20, 5, "hello world")
        let pane = CompositorPane(
            rect: rect(20, 5), grid: grid, isActive: true,
            selection: CopyModeViewportSelection(kind: .block, startRow: 0, startColumn: 0, endRow: 0, endColumn: 2)
        )
        let out = comp.render(panes: [pane], status: "-- VISUAL --")
        XCTAssertTrue(out.contains("48;5;4"), "selection cells should use the palette-4 background")
    }

    func testSearchShadingEmitsPaletteBackground() {
        let comp = GridCompositor(cols: 20, rows: 6)
        let grid = snapshot(20, 5, "needle here")
        let pane = CompositorPane(
            rect: rect(20, 5), grid: grid, isActive: true,
            searchHits: [CopyModeMatch(line: 0, startColumn: 0, endColumn: 6)]
        )
        let out = comp.render(panes: [pane], status: "/needle")
        XCTAssertTrue(out.contains("48;5;3"), "search hits should use the palette-3 background")
    }

    func testCopyModeCursorIsPlaced() {
        let comp = GridCompositor(cols: 20, rows: 6)
        let grid = snapshot(20, 5, "scrolled content")
        let pane = CompositorPane(
            rect: rect(20, 5), grid: grid, isActive: true,
            copyModeCursor: (row: 2, column: 3)
        )
        let out = comp.render(panes: [pane], status: "-- NORMAL --")
        // Real cursor positioned at row 3, col 4 (1-based) then shown.
        XCTAssertTrue(out.contains("\u{1b}[3;4H"), "copy-mode cursor should be placed at its cell")
        XCTAssertTrue(out.contains("\u{1b}[?25h"))
    }
}
