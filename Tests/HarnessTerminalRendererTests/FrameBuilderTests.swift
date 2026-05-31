import XCTest
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

// XCTest pulls in ApplicationServices, whose QuickDraw `RGBColor` shadows ours.
private typealias RGBColor = HarnessTheme.RGBColor

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

    func testSelectionSpanContainsLinearRange() {
        // Rows 0..2; start (0,5), end (2,3). Linear (line-wrapping) coverage.
        let sel = TerminalSelection((0, 5), (2, 3))
        XCTAssertFalse(sel.contains(row: 0, column: 4)) // before start on first row
        XCTAssertTrue(sel.contains(row: 0, column: 5))  // start
        XCTAssertTrue(sel.contains(row: 0, column: 9))  // rest of first row
        XCTAssertTrue(sel.contains(row: 1, column: 0))  // full middle row
        XCTAssertTrue(sel.contains(row: 2, column: 3))  // end
        XCTAssertFalse(sel.contains(row: 2, column: 4)) // after end on last row
        XCTAssertFalse(sel.contains(row: 3, column: 0)) // out of range
    }

    func testSelectionNormalizesReversedEndpoints() {
        // Dragging up/left should normalize to the same span.
        XCTAssertEqual(TerminalSelection((2, 3), (0, 5)), TerminalSelection((0, 5), (2, 3)))
    }

    func testSelectedCellsTakeSelectionColors() {
        let selBg = RGBColor(red: 10, green: 20, blue: 30)
        let selFg = RGBColor(red: 200, green: 210, blue: 220)
        let b = FrameBuilder(theme: theme, selectionBackground: selBg, selectionForeground: selFg)
        let term = HarnessGridTerminal(cols: 10, rows: 1)!
        term.feed("ABCDE")
        let f = b.build(term.readGrid()!, selection: TerminalSelection((0, 1), (0, 3)))
        // Selected cells (1...3) take the selection colors.
        for col in 1 ... 3 {
            XCTAssertEqual(f.cell(row: 0, column: col)!.background, RenderColor(selBg))
            XCTAssertEqual(f.cell(row: 0, column: col)!.foreground, RenderColor(selFg))
        }
        // Outside the selection keeps the default background.
        XCTAssertEqual(f.cell(row: 0, column: 0)!.background, RenderColor(theme.background))
    }

    // MARK: - Incremental rebuild (dirty-row reuse)

    func testIncrementalRebuildMatchesFullRebuild() {
        let b = builder
        let term = HarnessGridTerminal(cols: 10, rows: 3)!
        term.feed("abc")
        _ = term.consumeDamage()                  // clear the initial full damage
        let f1 = b.build(term.readGrid()!)        // plain baseline
        term.feed("\u{1b}[2;1HXYZ")               // rewrite row 1 only
        let damage = term.consumeDamage()
        XCTAssertFalse(damage.full)               // a single-row change must not be full
        let snap = term.readGrid()!
        let incremental = b.build(snap, region: nil, reusing: f1, damage: damage)
        // Reusing clean rows 0 and 2 must be byte-identical to rebuilding the whole grid.
        XCTAssertEqual(incremental.cells, b.build(snap).cells)
    }

    func testIncrementalFallsBackOnFullDamage() {
        let b = builder
        let term = HarnessGridTerminal(cols: 8, rows: 2)!
        term.feed("ab")
        _ = term.consumeDamage()
        let f1 = b.build(term.readGrid()!)
        term.feed("\u{1b}[2J\u{1b}[1;1HZ")        // clear (full damage) + write
        let damage = term.consumeDamage()
        XCTAssertTrue(damage.full)
        let snap = term.readGrid()!
        let incremental = b.build(snap, region: nil, reusing: f1, damage: damage)
        XCTAssertEqual(incremental.cells, b.build(snap).cells)
    }

    func testReuseIgnoredWhenSelectionPresent() {
        // A selection bakes per-cell highlight colors the damage set doesn't track, so passing
        // `reusing:`/`damage:` alongside a region must still produce a correct full build.
        let b = FrameBuilder(theme: theme, selectionBackground: RGBColor(red: 1, green: 2, blue: 3))
        let term = HarnessGridTerminal(cols: 6, rows: 2)!
        term.feed("hi")
        _ = term.consumeDamage()
        let f1 = b.build(term.readGrid()!)
        term.feed("\u{1b}[2;1Hyo")
        let damage = term.consumeDamage()
        let snap = term.readGrid()!
        let sel = TerminalSelection((0, 0), (0, 2))
        let withReuse = b.build(snap, region: .linear(sel), reusing: f1, damage: damage)
        XCTAssertEqual(withReuse.cells, b.build(snap, region: .linear(sel)).cells)
    }

    // MARK: - OSC 133 prompt gutter

    private func osc133(_ body: String) -> String { "\u{1b}]133;\(body)\u{07}" }

    func testNoPromptGutterWithoutShellIntegration() {
        let f = frame("plain output")
        XCTAssertTrue(f.promptGutter.isEmpty)
    }

    func testPromptGutterNeutralBeforeExit() {
        // A prompt mark with no exit yet → neutral stripe (palette bright-black, index 8).
        let f = frame(osc133("A") + "$ ")
        XCTAssertEqual(f.promptGutter[0], RenderColor(theme.palette[8]))
    }

    func testPromptGutterGreenOnSuccess() {
        let f = frame(osc133("A") + "$ true\r\n" + osc133("D;0"), rows: 4)
        XCTAssertEqual(f.promptGutter[0], RenderColor(theme.palette[2]))   // ANSI green
    }

    func testPromptGutterRedOnFailure() {
        let f = frame(osc133("A") + "$ false\r\n" + osc133("D;1"), rows: 4)
        XCTAssertEqual(f.promptGutter[0], RenderColor(theme.palette[1]))   // ANSI red
    }

    func testPromptGutterDisabledSkipsStripe() {
        // With the gutter disabled, marks still exist on the snapshot but no stripe is resolved.
        let b = FrameBuilder(theme: theme, promptGutterEnabled: false)
        let term = HarnessGridTerminal(cols: 20, rows: 2)!
        term.feed(osc133("A") + "$ ")
        let f = b.build(term.readGrid()!)
        XCTAssertTrue(f.promptGutter.isEmpty, "no gutter when disabled")
    }
}
