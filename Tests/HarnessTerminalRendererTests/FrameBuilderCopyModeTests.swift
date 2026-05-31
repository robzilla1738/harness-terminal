import XCTest
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

// XCTest pulls in ApplicationServices, whose QuickDraw `RGBColor` shadows ours.
private typealias RGBColor = HarnessTheme.RGBColor

/// Covers the copy-mode rendering additions to `FrameBuilder`: block/linear selection
/// regions, search-hit highlights, shading precedence, and the copy-mode cursor override.
final class FrameBuilderCopyModeTests: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!

    private var selColor: RGBColor { theme.palette[4] }
    private var searchColor: RGBColor { theme.palette[3] }

    private func snapshot(_ lines: [String], cols: Int = 5, rows: Int = 3) -> TerminalGridSnapshot {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(lines.joined(separator: "\r\n"))
        return term.readGrid()!
    }

    private var builder: FrameBuilder {
        FrameBuilder(theme: theme, selectionBackground: selColor, searchBackground: searchColor)
    }

    func testBlockRegionHighlightsRectangleOnly() {
        let snap = snapshot(["abcde", "fghij", "klmno"])
        let f = builder.build(snap, region: .block(BlockSelection((0, 1), (2, 2))))
        for row in 0..<3 {
            for column in 0..<5 {
                let inBlock = (1...2).contains(column) // rows 0..2 all included
                let bg = f.cell(row: row, column: column)!.background
                if inBlock {
                    XCTAssertEqual(bg, RenderColor(selColor), "(\(row),\(column)) should be selected")
                } else {
                    XCTAssertNotEqual(bg, RenderColor(selColor), "(\(row),\(column)) should NOT be selected")
                }
            }
        }
    }

    func testSearchHighlightsApplyToHits() {
        let snap = snapshot(["abcde"])
        let hits = [TerminalSelection((0, 0), (0, 1))]
        let f = builder.build(snap, region: nil, searchHighlights: hits)
        XCTAssertEqual(f.cell(row: 0, column: 0)!.background, RenderColor(searchColor))
        XCTAssertEqual(f.cell(row: 0, column: 1)!.background, RenderColor(searchColor))
        XCTAssertNotEqual(f.cell(row: 0, column: 2)!.background, RenderColor(searchColor))
    }

    func testSelectionBeatsSearchOnOverlap() {
        let snap = snapshot(["abcde"])
        // Selection covers cols 0..2; a search hit at col 1 overlaps → selection wins.
        let f = builder.build(
            snap,
            region: .linear(TerminalSelection((0, 0), (0, 2))),
            searchHighlights: [TerminalSelection((0, 1), (0, 1))]
        )
        XCTAssertEqual(f.cell(row: 0, column: 1)!.background, RenderColor(selColor))
    }

    func testHighlightedCellsRequireBackgroundFill() {
        // Both selection and search highlights are opaque non-canvas fills, so their cells must
        // draw a background quad; a plain cell beside them stays skippable.
        let snap = snapshot(["abcde"])
        let f = builder.build(
            snap,
            region: .linear(TerminalSelection((0, 0), (0, 1))),
            searchHighlights: [TerminalSelection((0, 3), (0, 3))]
        )
        XCTAssertTrue(f.cell(row: 0, column: 0)!.drawBackground, "selected cell fills")
        XCTAssertTrue(f.cell(row: 0, column: 3)!.drawBackground, "search hit fills")
        XCTAssertFalse(f.cell(row: 0, column: 4)!.drawBackground, "plain default cell skips")
    }

    func testCopyModeCursorOverridesAndIsVisible() {
        let snap = snapshot(["abcde"])
        let f = builder.build(snap, region: nil, copyModeCursor: (row: 2, column: 3))
        XCTAssertEqual(f.cursor.row, 2)
        XCTAssertEqual(f.cursor.column, 3)
        XCTAssertTrue(f.cursor.visible)
    }

    func testLinearRegionMatchesLegacySelectionPath() {
        // The new region API and the original `selection:` overload must be byte-identical.
        let snap = snapshot(["abcde", "fghij"])
        let sel = TerminalSelection((0, 1), (1, 2))
        let legacy = builder.build(snap, selection: sel)
        let viaRegion = builder.build(snap, region: .linear(sel))
        XCTAssertEqual(legacy, viaRegion)
    }
}
