import XCTest
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

final class FrameBuilderTests: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!
    private var builder: FrameBuilder { FrameBuilder(theme: theme) }

    private func frame(_ bytes: String, cols: Int = 10, rows: Int = 3) -> TerminalFrame {
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        term.feed(bytes)
        return builder.build(term.readGrid()!)
    }

    func testFrameCoversWholeGrid() {
        let f = frame("hi", cols: 10, rows: 3)
        XCTAssertEqual(f.columns, 10)
        XCTAssertEqual(f.rows, 3)
        XCTAssertEqual(f.cells.count, 30)
    }

    func testBackgroundFilledForEveryCell() {
        // Even an empty cell carries the resolved default background.
        let f = frame("", cols: 4, rows: 1)
        for cell in f.cells {
            XCTAssertEqual(cell.background, RenderColor(theme.background))
        }
    }

    func testForegroundResolvesThroughTheme() {
        // SGR 31 -> ANSI red -> theme palette[1].
        let f = frame("\u{1b}[31mA")
        let cell = f.cell(row: 0, column: 0)!
        XCTAssertEqual(cell.codepoint, UInt32(UnicodeScalar("A").value))
        XCTAssertEqual(cell.foreground, RenderColor(theme.palette[1]))
        XCTAssertTrue(cell.hasGlyph)
    }

    func testSpaceHasNoGlyphButHasBackground() {
        let f = frame("a ")
        let space = f.cell(row: 0, column: 1)!
        XCTAssertFalse(space.hasGlyph)
        XCTAssertEqual(space.background, RenderColor(theme.background))
    }

    func testWideCharacterSpacerHasNoGlyph() {
        let f = frame("世")
        XCTAssertTrue(f.cell(row: 0, column: 0)!.hasGlyph)        // wide leading cell
        XCTAssertEqual(f.cell(row: 0, column: 0)!.width, .wide)
        XCTAssertFalse(f.cell(row: 0, column: 1)!.hasGlyph)       // spacer tail
    }

    func testInverseBakesIntoResolvedColors() {
        // Inverse swaps fg/bg before they reach the frame.
        let f = frame("\u{1b}[7mX")
        let cell = f.cell(row: 0, column: 0)!
        XCTAssertEqual(cell.foreground, RenderColor(theme.background))
        XCTAssertEqual(cell.background, RenderColor(theme.foreground))
    }

    func testCursorCarriedWithThemeColor() {
        let f = frame("\u{1b}[2;3Hx")
        // Cursor advanced past the 'x' printed at row1,col2 -> col3.
        XCTAssertTrue(f.cursor.visible)
        XCTAssertEqual(f.cursor.row, 1)
        XCTAssertEqual(f.cursor.column, 3)
        XCTAssertEqual(f.cursor.color, RenderColor(theme.cursor ?? theme.foreground))
    }

    func testRenderColorNormalizesChannels() {
        XCTAssertEqual(RenderColor(RGBColor(red: 255, green: 0, blue: 0)),
                       RenderColor(red: 1, green: 0, blue: 0, alpha: 1))
        let half = RenderColor(RGBColor(red: 255, green: 255, blue: 255, alpha: 0))
        XCTAssertEqual(half.alpha, 0)
    }
}
