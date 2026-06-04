import XCTest
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessCopyMode

/// Copy-mode must treat a cell carrying combining marks as one grapheme in one column, so a
/// selection over Thai copies "ที่" (base + vowel + tone), not a bare consonant or a shifted column.
final class ThaiClusterCopyTests: XCTestCase {
    /// A single-line grid whose first cell carries combining marks.
    private struct ThaiGrid: CopyModeGridSource {
        let cells: [TerminalGridCell]
        var totalLines: Int { 1 }
        var viewportRows: Int { 1 }
        var columns: Int { cells.count }
        func line(_ index: Int) -> [TerminalGridCell] { index == 0 ? cells : [] }
    }

    func testRenderedLineFoldsCombiningIntoOneCharacter() {
        // ที่ = ท + ◌ี + ◌่ folded onto one cell, then plain "x".
        let cells = [
            TerminalGridCell(codepoint: 0x0E17, combining0: 0x0E35, combining1: 0x0E48),
            TerminalGridCell(codepoint: UInt32(UnicodeScalar("x").value)),
        ]
        let rl = ThaiGrid(cells: cells).renderedLine(0)
        XCTAssertEqual(rl.chars.count, 2, "two columns: the cluster + 'x'")
        XCTAssertEqual(rl.chars.first.map(String.init), "ที่", "the cluster is one Character")
        XCTAssertEqual(rl.columnOf, [0, 1], "column mapping stays 1:1 with cells")
        XCTAssertEqual(rl.widthOf, [1, 1], "combining marks add no display width")
    }
}
