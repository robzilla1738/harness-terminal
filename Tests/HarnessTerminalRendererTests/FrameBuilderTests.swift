import XCTest
import HarnessCore
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

    /// Scroll-delta reuse must be byte-identical to a full rebuild at every offset: walk a
    /// deterministic pseudo-random offset sequence over content with colors, wide chars,
    /// decorations, and wrapped lines, shifting from the previous frame at each step.
    func testBuildShiftedMatchesFullBuildAcrossScrollWalk() {
        let cols = 24, rows = 6
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 80 {
            term.feed("\u{1b}[3\(i % 8)mL\(i) 漢字 \u{1b}[4mu\(i)\u{1b}[24m \(String(repeating: "w", count: 30))\r\n")
        }
        let sharedBuilder = builder // one deterministic config for the whole walk
        var offset = 0
        var previous = sharedBuilder.build(term.readGrid()!)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var shiftedSteps = 0
        for step in 0 ..< 60 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let newOffset = Int(seed % 9) // small offsets → many |delta| < rows shift steps
            let delta = newOffset - offset
            guard let snap = newOffset > 0
                ? term.readGrid(scrollbackOffset: newOffset) : term.readGrid()
            else { return XCTFail("snapshot failed at step \(step)") }
            let full = sharedBuilder.build(snap)
            if delta != 0, let shifted = sharedBuilder.buildShifted(snap, reusing: previous, shift: delta) {
                XCTAssertEqual(shifted, full, "offset \(offset)→\(newOffset) (step \(step))")
                previous = shifted
                shiftedSteps += 1
            } else {
                previous = full
            }
            offset = newOffset
        }
        XCTAssertGreaterThan(shiftedSteps, 10, "the walk should exercise the shift path")
    }

    /// Output-scroll reuse must be byte-identical to a full rebuild: drive real output through
    /// the engine (streamed lines, mid-screen overwrites, multi-line bursts), consume the damage
    /// hint each step, and rebuild via `buildShifted(freshRows:)` exactly as the surface view's
    /// off-main plain path does. The engine's `scroll`/`scrolledRows` contract and the builder's
    /// shift-copy must agree at every step.
    func testBuildShiftedWithFreshRowsMatchesFullBuildOnOutputScroll() {
        let cols = 24, rows = 6
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 10 {
            term.feed("\u{1b}[3\(i % 8)mfill \(i) 漢字 \u{1b}[4mu\(i)\u{1b}[0m\r\n")
        }
        let b = builder
        _ = term.consumeDamage()
        var previous = b.build(term.readGrid()!)
        var hintSteps = 0
        for step in 0 ..< 40 {
            switch step % 5 {
            case 0: // plain streamed line (one scroll)
                term.feed("\u{1b}[3\(step % 8)mnew \(step) wide 漢\u{1b}[0m\r\n")
            case 1: // burst (two scrolls in one consume window)
                term.feed("burst-a \(step)\r\nburst-b \(step)\r\n")
            case 2: // scroll, then overwrite a moved top row (fresh row inside the kept band)
                term.feed("scrolled \(step)\r\n\u{1b}[2;3Hovr\u{1b}[\(rows);1H")
            case 3: // decorated content with a trailing partial line (no scroll on the write)
                term.feed("\u{1b}[7minverse \(step)\u{1b}[27m\r\n")
            default: // wide chars crossing the wrap (wrap + scroll interplay)
                term.feed(String(repeating: "漢", count: cols / 2 + 2) + "\r\n")
            }
            let damage = term.consumeDamage()
            guard let snap = term.readGrid() else { return XCTFail("snapshot failed") }
            let full = b.build(snap)
            if damage.scroll != 0, !damage.full, !damage.scrolledRows.isEmpty,
               let shifted = b.buildShifted(snap, reusing: previous, shift: damage.scroll,
                                            freshRows: damage.rows.subtracting(damage.scrolledRows)) {
                XCTAssertEqual(shifted, full, "step \(step) (scroll \(damage.scroll))")
                previous = shifted
                hintSteps += 1
            } else {
                previous = full
            }
        }
        XCTAssertGreaterThan(hintSteps, 15, "the walk should exercise the hint path")
    }

    /// The cell-overlay pass must be byte-identical to baking: a plain build re-shaded by
    /// `applyHighlights` equals `build(region:searchHighlights:)` for linear/block selections,
    /// find hits, and the selection-beats-search precedence — across colored, wide-char,
    /// decorated, and inverse content. Passing extra (unshaded) rows must be harmless: they
    /// re-resolve to their plain cells.
    func testApplyHighlightsMatchesBakedBuild() {
        let cols = 24, rows = 8
        let term = HarnessGridTerminal(cols: cols, rows: rows)!
        for i in 0 ..< 7 {
            term.feed("\u{1b}[3\(i % 8);4\((i + 1) % 8)mrow \(i) 漢字 \u{1b}[4mu\(i)\u{1b}[24m \u{1b}[7minv\u{1b}[27m\r\n")
        }
        term.feed("tail row")
        let snap = term.readGrid()!
        let b = FrameBuilder(
            theme: theme,
            selectionBackground: RGBColor(red: 60, green: 80, blue: 200),
            searchBackground: RGBColor(red: 200, green: 180, blue: 40)
        )
        let cases: [(SelectionRegion?, [TerminalSelection], String)] = [
            (.linear(TerminalSelection((1, 3), (4, 10))), [], "linear"),
            (.block(BlockSelection((2, 2), (5, 9))), [], "block"),
            (nil, [TerminalSelection((0, 0), (0, 5)), TerminalSelection((3, 4), (3, 9))], "find"),
            (.linear(TerminalSelection((2, 0), (3, 23))), [TerminalSelection((2, 5), (2, 8))], "precedence"),
            (.linear(TerminalSelection((0, 0), (7, 23))), [], "whole grid"),
        ]
        for (region, hits, name) in cases {
            let baked = b.build(snap, region: region, searchHighlights: hits)
            var shaded = b.build(snap)
            b.applyHighlights(into: &shaded, from: snap, region: region, searchHighlights: hits,
                              rows: IndexSet(integersIn: 0 ..< rows)) // extra rows must be harmless
            XCTAssertEqual(shaded, baked, name)
        }
    }

    func testApplyHighlightsWithoutShadingIsANoOp() {
        let snap = HarnessGridTerminal(cols: 10, rows: 3)!.readGrid()!
        let b = builder
        let clean = b.build(snap)
        var copy = clean
        b.applyHighlights(into: &copy, from: snap, region: nil, searchHighlights: [],
                          rows: IndexSet(integersIn: 0 ..< 3))
        XCTAssertEqual(copy, clean)
    }

    func testBuildShiftedRejectsInapplicableShifts() {
        let term = HarnessGridTerminal(cols: 10, rows: 3)!
        for i in 0 ..< 12 { term.feed("line \(i)\r\n") }
        let b = builder
        let live = b.build(term.readGrid()!)
        let snap = term.readGrid(scrollbackOffset: 1)!
        XCTAssertNil(b.buildShifted(snap, reusing: live, shift: 0), "zero shift is a no-op")
        XCTAssertNil(b.buildShifted(snap, reusing: live, shift: 3), "|shift| ≥ rows leaves nothing to reuse")
        let small = HarnessGridTerminal(cols: 8, rows: 3)!
        small.feed("x")
        XCTAssertNil(b.buildShifted(small.readGrid()!, reusing: live, shift: 1), "geometry mismatch")
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

    func testProgramCursorShapeOverridesUserDefaultStyle() {
        let term = HarnessGridTerminal(cols: 4, rows: 1)!
        term.feed("\u{1b}[5 q") // blinking bar

        let f = FrameBuilder(theme: theme, cursorStyle: .block).build(term.readGrid()!)

        XCTAssertEqual(f.cursor.style, .bar)
    }

    func testDefaultCursorShapeHonorsUserStyle() {
        let term = HarnessGridTerminal(cols: 4, rows: 1)!

        let f = FrameBuilder(theme: theme, cursorStyle: .bar).build(term.readGrid()!)

        XCTAssertEqual(f.cursor.style, .bar)
    }

    func testCursorResetAfterProgramShapeReturnsToUserStyle() {
        // The TUI exit path: program shape (steady block) then `CSI 0 SP q` reset — the build
        // must resolve back to the user's configured style, not keep the program's block.
        let term = HarnessGridTerminal(cols: 4, rows: 1)!
        term.feed("\u{1b}[2 q")
        XCTAssertEqual(FrameBuilder(theme: theme, cursorStyle: .bar).build(term.readGrid()!).cursor.style, .block)
        term.feed("\u{1b}[0 q")
        XCTAssertEqual(FrameBuilder(theme: theme, cursorStyle: .bar).build(term.readGrid()!).cursor.style, .bar)
    }

    func testRenderColorNormalizesChannels() {
        XCTAssertEqual(RenderColor(RGBColor(red: 255, green: 0, blue: 0)),
                       RenderColor(red: 1, green: 0, blue: 0, alpha: 1))
        let half = RenderColor(RGBColor(red: 255, green: 255, blue: 255, alpha: 0))
        XCTAssertEqual(half.alpha, 0)
    }

    func testRenderColorConvertsSRGBRedToDisplayP3Reference() {
        let p3 = RenderColor(RGBColor(red: 255, green: 0, blue: 0), gamut: .displayP3)

        XCTAssertEqual(p3.red, 0.92, accuracy: 0.01)
        XCTAssertEqual(p3.green, 0.20, accuracy: 0.01)
        XCTAssertEqual(p3.blue, 0.14, accuracy: 0.01)
        XCTAssertEqual(p3.alpha, 1)
    }

    func testVividRenderingConvertsThenAppliesCappedLift() {
        let red = RGBColor(red: 255, green: 0, blue: 0)
        let converted = RenderColor(red, gamut: .displayP3)
        let vivid = RenderColor(red, renderingMode: .vivid, gamut: .auto)

        XCTAssertGreaterThan(vivid.red, converted.red)
        XCTAssertLessThanOrEqual(vivid.red, 1)
        XCTAssertLessThan(vivid.green, converted.green)
        XCTAssertLessThan(vivid.blue, converted.blue)
    }

    func testClearColorMatchesDefaultCellBackgroundInAccurateAndVividModes() {
        let bg = RGBColor(red: 32, green: 64, blue: 128)
        let fg = RGBColor(red: 230, green: 231, blue: 232)
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: theme.palette),
            defaultForeground: fg,
            defaultBackground: bg
        )
        let term = HarnessGridTerminal(cols: 1, rows: 1)!
        let snapshot = term.readGrid()!

        for mode in [TerminalColorRenderingMode.accurate, .vivid] {
            let builder = FrameBuilder(
                resolver: resolver,
                cursorColor: fg,
                canvasOpacity: 0.42,
                colorRendering: mode,
                colorGamut: .auto
            )
            let frame = builder.build(snapshot)
            let clear = builder.renderColor(bg, alpha: 0.42)

            XCTAssertEqual(frame.cell(row: 0, column: 0)?.background, clear, "\(mode) cell bg matches clear")
            XCTAssertFalse(frame.cell(row: 0, column: 0)?.drawBackground ?? true)
        }
    }

    func testTextAndColorRenderingAreOrthogonal() {
        var settings = HarnessSettings()
        let source = RGBColor(red: 255, green: 0, blue: 0)
        let initialColor = RenderColor(
            source,
            renderingMode: settings.colorRendering,
            gamut: settings.colorGamut
        )
        let initialGamma = settings.textRendering.glyphGamma

        settings.textRendering = .crisp
        XCTAssertNotEqual(settings.textRendering.glyphGamma, initialGamma)
        XCTAssertEqual(
            RenderColor(source, renderingMode: settings.colorRendering, gamut: settings.colorGamut),
            initialColor
        )

        let crispGamma = settings.textRendering.glyphGamma
        settings.colorRendering = .vivid
        XCTAssertNotEqual(
            RenderColor(source, renderingMode: settings.colorRendering, gamut: settings.colorGamut),
            initialColor
        )
        XCTAssertEqual(settings.textRendering.glyphGamma, crispGamma)
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

    func testSelectionForegroundFallbackReContrastsAgainstSelectionBackground() {
        // Dim grey text on a near-black bg with minimum contrast on: the resolver lifts the
        // fg against the CELL background (dark -> lifts toward white). The selection draws a
        // LIGHT background, so forwarding that lifted fg verbatim would be unreadable — the
        // builder must re-ensure the ratio against the background it actually draws.
        let dark = RGBColor(red: 10, green: 10, blue: 12)
        let dim = RGBColor(red: 70, green: 70, blue: 74)
        let selBg = RGBColor(red: 200, green: 205, blue: 215)
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: theme.palette),
            defaultForeground: dim,
            defaultBackground: dark,
            minimumContrast: 4.5
        )
        let b = FrameBuilder(resolver: resolver, cursorColor: dim, selectionBackground: selBg)
        let term = HarnessGridTerminal(cols: 6, rows: 1)!
        term.feed("ABC")
        let f = b.build(term.readGrid()!, selection: TerminalSelection((0, 0), (0, 2)))
        let fg = f.cell(row: 0, column: 0)!.foreground
        let fgRGB = RGBColor(
            red: UInt8(min(255, max(0, (fg.red * 255).rounded()))),
            green: UInt8(min(255, max(0, (fg.green * 255).rounded()))),
            blue: UInt8(min(255, max(0, (fg.blue * 255).rounded())))
        )
        XCTAssertGreaterThanOrEqual(
            CellColorResolver.contrastRatio(fgRGB, selBg), 4.4,
            "selected-cell fg must meet the contrast floor against the selection background"
        )
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

    // MARK: - Background fill skipping

    func testDefaultCanvasCellsSkipBackgroundFill() {
        // Blank cells resolve to the canvas background, which the renderer already clears to,
        // so they must not request a redundant background quad — but they still carry the color.
        let f = frame("", cols: 4, rows: 1)
        for cell in f.cells {
            XCTAssertFalse(cell.drawBackground, "blank default cell at col \(cell.column) should skip its fill")
            XCTAssertEqual(cell.background, RenderColor(theme.background))
        }
    }

    func testExplicitBackgroundRequiresFill() {
        // SGR 41 -> ANSI red background: not the canvas color, so the quad must be drawn.
        let f = frame("\u{1b}[41mX")
        XCTAssertTrue(f.cell(row: 0, column: 0)!.drawBackground)
    }

    func testInverseRequiresFill() {
        // Inverse promotes the foreground into the bg slot, so it's no longer the canvas color.
        let f = frame("\u{1b}[7mX")
        XCTAssertTrue(f.cell(row: 0, column: 0)!.drawBackground)
    }

    func testSelectionRequiresFillWhileOutsideSkips() {
        let selBg = RGBColor(red: 10, green: 20, blue: 30)
        let b = FrameBuilder(theme: theme, selectionBackground: selBg)
        let term = HarnessGridTerminal(cols: 10, rows: 1)!
        term.feed("ABCDE")
        let f = b.build(term.readGrid()!, selection: TerminalSelection((0, 1), (0, 3)))
        for col in 1 ... 3 {
            XCTAssertTrue(f.cell(row: 0, column: col)!.drawBackground, "selected col \(col) fills")
        }
        // A default-background cell outside the selection stays skippable (glyph or blank).
        XCTAssertFalse(f.cell(row: 0, column: 0)!.drawBackground, "unselected 'A' skips its fill")
        XCTAssertFalse(f.cell(row: 0, column: 8)!.drawBackground, "blank cell skips its fill")
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

    /// SGR 5/25 blink rides the grid cell into `RenderCell.blink` (the renderer's phase
    /// driver keys on it); plain cells stay `blink == false`.
    func testBlinkAttributeReachesRenderCells() {
        let term = HarnessGridTerminal(cols: 10, rows: 1)!
        term.feed("a\u{1b}[5mb\u{1b}[25mc")
        let f = builder.build(term.readGrid()!)
        XCTAssertFalse(f.cell(row: 0, column: 0)!.blink)
        XCTAssertTrue(f.cell(row: 0, column: 1)!.blink, "SGR 5 marks the cell as blinking")
        XCTAssertFalse(f.cell(row: 0, column: 2)!.blink, "SGR 25 clears blink")
    }

    /// `TerminalFrame.hasBlink` is computed once at build so the view's blink-timer
    /// decision is a field read, not a per-present O(cells) scan on the main thread.
    func testFrameHasBlinkComputedAtBuild() {
        let term = HarnessGridTerminal(cols: 10, rows: 2)!
        term.feed("plain")
        XCTAssertFalse(builder.build(term.readGrid()!).hasBlink)
        term.feed("\u{1b}[5mB\u{1b}[25m")
        XCTAssertTrue(builder.build(term.readGrid()!).hasBlink)
        // The shifted fast path computes it from its assembled rows too.
        let snap = term.readGrid()!
        if let shifted = builder.buildShifted(snap, reusing: builder.build(snap), shift: 1) {
            XCTAssertTrue(shifted.hasBlink)
        }
    }
}
