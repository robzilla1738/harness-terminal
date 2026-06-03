import XCTest
@testable import HarnessTerminalRenderer
@testable import HarnessTerminalEngine

/// The frame builder must carry a cell's combining marks onto its RenderCell so the shaping path
/// can compose them.
final class RenderCellMarksTests: XCTestCase {
    func testMarksPropagateFromSnapshotToRenderCell() {
        var cell = TerminalGridCell(codepoint: 0x0E17)
        cell.marks = [0x0E35, 0x0E48]
        let render = RenderCell(
            row: 0, column: 0, codepoint: cell.codepoint,
            foreground: .init(red: 1, green: 1, blue: 1, alpha: 1),
            background: .init(red: 0, green: 0, blue: 0, alpha: 1),
            underlineColor: .init(red: 1, green: 1, blue: 1, alpha: 1),
            bold: false, italic: false, underline: .none, strikethrough: false,
            overline: false, width: .normal, marks: cell.marks
        )
        XCTAssertEqual(render.marks ?? [], [0x0E35, 0x0E48])
    }
}
