import Foundation
import HarnessCore
import HarnessTerminalEngine
@testable import HarnessTerminalKit
import XCTest

final class GridCompositorTests: XCTestCase {
    /// Build a snapshot by feeding bytes to a real renderer-free terminal.
    private func snapshot(_ cols: Int, _ rows: Int, _ bytes: String) -> TerminalGridSnapshot {
        guard let term = HarnessGridTerminal(cols: cols, rows: rows) else {
            fatalError("HarnessGridTerminal create failed")
        }
        term.feed(bytes)
        return term.readGrid()!
    }

    private func pane(_ x: Int, _ y: Int, _ cols: Int, _ rows: Int, _ grid: TerminalGridSnapshot, active: Bool = true) -> CompositorPane {
        CompositorPane(
            rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: x, y: y, cols: cols, rows: rows),
            grid: grid,
            isActive: active
        )
    }

    func testRendersPaneText() {
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 24, "Hello")
        let out = comp.render(panes: [pane(0, 0, 80, 24, grid)])
        XCTAssertTrue(out.contains("Hello"), "composited frame should contain pane text")
        // Positions the real cursor (active pane, cursor visible).
        XCTAssertTrue(out.contains("\u{1b}[?25h"), "should re-show the cursor at the active pane")
    }

    func testEmitsColorSGR() {
        let comp = GridCompositor(cols: 80, rows: 24)
        // Red foreground (palette 1).
        let grid = snapshot(80, 24, "\u{1b}[31mR")
        let out = comp.render(panes: [pane(0, 0, 80, 24, grid)])
        XCTAssertTrue(out.contains("38;5;1"), "should emit palette-1 foreground SGR")
    }

    func testEmitsTrueColorSGR() {
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 24, "\u{1b}[48;2;10;20;30mX")
        let out = comp.render(panes: [pane(0, 0, 80, 24, grid)])
        XCTAssertTrue(out.contains("48;2;10;20;30"), "should emit true-color background SGR")
    }

    func testDiffSkipsUnchangedSecondFrame() {
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 24, "Hello")
        let first = comp.render(panes: [pane(0, 0, 80, 24, grid)])
        let second = comp.render(panes: [pane(0, 0, 80, 24, grid)])
        XCTAssertTrue(first.contains("Hello"))
        XCTAssertFalse(second.contains("Hello"), "unchanged second frame should not re-emit pane text")
        XCTAssertLessThan(second.count, first.count / 4, "diff frame should be far smaller")
    }

    func testDrawsBordersBetweenPanes() {
        let comp = GridCompositor(cols: 81, rows: 24)
        let left = snapshot(40, 24, "L")
        let right = snapshot(40, 24, "R")
        let out = comp.render(panes: [
            pane(0, 0, 40, 24, left, active: true),
            pane(41, 0, 40, 24, right, active: false),
        ])
        // Column 40 is the divider gap -> a vertical box-drawing line.
        XCTAssertTrue(out.unicodeScalars.contains(Unicode.Scalar(0x2502)!), "should draw a vertical divider │")
        XCTAssertTrue(out.contains("L") && out.contains("R"), "both panes painted")
    }

    func testStatusLineRendered() {
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 23, "x")
        let out = comp.render(panes: [pane(0, 0, 80, 23, grid)], status: "harness")
        XCTAssertTrue(out.contains("harness"), "status text should appear")
    }

    func testMultiLineStatusRendersAllRows() {
        // tmux `status 2`: two status rows reserved at the bottom; the pane area is the
        // top `rows - 2`. Both rows render and pane content above them is preserved.
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 22, "P")
        let out = comp.render(panes: [pane(0, 0, 80, 22, grid)], statusLines: [
            [StyledSegment(text: "MAINLINE")],
            [StyledSegment(text: "UPPERLINE")],
        ])
        XCTAssertTrue(out.contains("MAINLINE"), "bottom (main) status line renders")
        XCTAssertTrue(out.contains("UPPERLINE"), "second status line renders above it")
        XCTAssertTrue(out.contains("P"), "pane content still renders above the status band")
        // Bottom row is 24 (1-based); the second status line sits on row 23.
        XCTAssertTrue(out.contains("\u{1b}[24;1H"), "main line painted on the last row")
        XCTAssertTrue(out.contains("\u{1b}[23;1H"), "second line painted on the row above")
    }

    func testTopStatusPositionPaintsBandAtTopAndPanesBelow() {
        // tmux `status-position top` with `status 2`: the band sits at the TOP — main line on
        // row 1, the extra row just below it — and the pane area is pushed down to start below
        // the band, exactly the `yOrigin = statusCount` the attach client solves panes with.
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 22, "P")
        let out = comp.render(
            panes: [pane(0, 2, 80, 22, grid)], // yOrigin = statusCount (2)
            statusLines: [
                [StyledSegment(text: "MAINLINE")],
                [StyledSegment(text: "LOWERLINE")],
            ],
            statusPosition: .top
        )
        XCTAssertTrue(out.contains("MAINLINE") && out.contains("LOWERLINE") && out.contains("P"))
        // Main line on the top row (1), the extra row just below it (2).
        XCTAssertTrue(out.contains("\u{1b}[1;1H"), "main line painted on the top row")
        XCTAssertTrue(out.contains("\u{1b}[2;1H"), "second line painted on the row below it")
        // Top-to-bottom paint order proves the band is above the panes: main → extra → pane.
        let iMain = out.range(of: "MAINLINE")!.lowerBound
        let iExtra = out.range(of: "LOWERLINE")!.lowerBound
        let iPane = out.range(of: "P")!.lowerBound
        XCTAssertTrue(iMain < iExtra && iExtra < iPane, "band paints above the pane content")
    }

    func testBottomStatusPositionMatchesDefault() {
        // The explicit `.bottom` argument is byte-identical to the default overload.
        let grid = snapshot(80, 23, "x")
        let a = GridCompositor(cols: 80, rows: 24).render(panes: [pane(0, 0, 80, 23, grid)], statusLines: [[StyledSegment(text: "S")]])
        let b = GridCompositor(cols: 80, rows: 24).render(panes: [pane(0, 0, 80, 23, grid)], statusLines: [[StyledSegment(text: "S")]], statusPosition: .bottom)
        XCTAssertEqual(a, b, "default position is .bottom — no behavior change for existing callers")
    }

    func testPaneBaseStyleDimsDefaultCells() {
        // `window-style bg=colour235`: a default-colored cell in an inactive pane gets the
        // base background (palette 235), while an explicitly-colored cell is untouched.
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 24, "A\u{1b}[41mB") // A = default bg, B = red (palette 1) bg
        var p = pane(0, 0, 80, 24, grid, active: false)
        p.baseBackground = .palette(235)
        let out = comp.render(panes: [p])
        XCTAssertTrue(out.contains("48;5;235"), "default-bg cell should take the base background")
        XCTAssertTrue(out.contains("48;5;1"), "explicitly-colored cell keeps its own background")
    }

    func testPaneBorderLabelDrawnOnLabelRow() {
        // A pane with a reserved top label row draws its pane-border-format label there.
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 23, "x")
        let rect = PaneRect(paneID: UUID(), surfaceID: UUID(), x: 0, y: 1, cols: 80, rows: 23, labelRow: 0)
        let p = CompositorPane(rect: rect, grid: grid, isActive: true, borderLabel: " 0 myshell ")
        let out = comp.render(panes: [p])
        XCTAssertTrue(out.contains("myshell"), "border label text should render on the label row")
        // Drawn on row 1 (1-based) = the reserved labelRow 0.
        XCTAssertTrue(out.contains("\u{1b}[1;"), "label drawn on the top reserved row")
        _ = rect
    }

    func testPaneBorderLabelWidthAware() {
        // The label is centered + placed by display width, not scalar count. A combining mark is
        // zero-width (folded onto its base cell, not given its own column), and a wide glyph advances
        // two cells so a following character isn't clobbered.
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 23, "x")
        let rect = PaneRect(paneID: UUID(), surfaceID: UUID(), x: 0, y: 1, cols: 80, rows: 23, labelRow: 0)

        // NFD "café" = c a f e + combining acute (5 scalars, 4 display columns). The acute folds onto
        // the 'e' cell and is re-emitted, so the label reads "café" (canonically equal to NFC "café").
        let nfd = CompositorPane(rect: rect, grid: grid, isActive: true, borderLabel: "cafe\u{0301}")
        XCTAssertTrue(comp.render(panes: [nfd]).contains("café"), "base letters + folded combining mark render as café")

        // A wide CJK glyph followed by ASCII: both must survive (the ASCII lands two cells over).
        let wide = CompositorPane(rect: rect, grid: grid, isActive: true, borderLabel: "中A")
        let out = comp.render(panes: [wide])
        XCTAssertTrue(out.contains("中"), "wide glyph renders")
        XCTAssertTrue(out.contains("A"), "following ASCII letter still renders")
    }

    func testReemitsThaiPaneContentWithCombiningMarks() {
        // A remote pane's Thai content must be re-emitted to the client terminal with its combining
        // marks intact (the engine stored them on the base cell), not dropped to bare consonants.
        let comp = GridCompositor(cols: 40, rows: 6)
        let grid = snapshot(40, 6, "ที่นี่")
        let out = comp.render(panes: [pane(0, 0, 40, 6, grid)])
        XCTAssertTrue(out.contains("ที่นี่"), "composited frame re-emits the Thai cluster")
    }

    func testNoBaseStyleLeavesCellsUntouched() {
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 24, "A")
        let out = comp.render(panes: [pane(0, 0, 80, 24, grid, active: false)])
        XCTAssertFalse(out.contains("48;5;235"), "no base style → no background substitution")
    }

    func testSingleLineStatusDelegatesToStatusLines() {
        // The legacy `status:`/`statusSegments:` path must stay byte-compatible: one
        // bottom row, classic inverse band.
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 23, "x")
        let out = comp.render(panes: [pane(0, 0, 80, 23, grid)], statusSegments: [StyledSegment(text: "seg")])
        XCTAssertTrue(out.contains("seg"))
        XCTAssertTrue(out.contains("\u{1b}[24;1H"), "single status line on the last row")
    }

    func testEmitsExtendedAttributeSGR() {
        let comp = GridCompositor(cols: 80, rows: 24)
        // Strikethrough (9), faint/dim (2), blink (5), curly underline (4:3) — each
        // isolated so the changed cell re-emits a self-contained SGR from reset.
        for (seq, expect) in [("\u{1b}[9mX", "0;9m"),
                              ("\u{1b}[2mX", "0;2m"),
                              ("\u{1b}[5mX", "0;5m"),
                              ("\u{1b}[4:3mX", "0;4:3m")] {
            let fresh = GridCompositor(cols: 80, rows: 24)
            let grid = snapshot(80, 24, seq)
            let out = fresh.render(panes: [pane(0, 0, 80, 24, grid)])
            XCTAssertTrue(out.contains(expect), "expected SGR \(expect) for sequence \(seq); got none")
        }
        _ = comp
    }

    func testRenderCellScalarFallsBackToSpace() {
        XCTAssertEqual(RenderCell(codepoint: 0).scalar, Unicode.Scalar(0x20))
        // 0xD800 is a lone surrogate — not a valid scalar — must fall back to space.
        XCTAssertEqual(RenderCell(codepoint: 0xD800).scalar, Unicode.Scalar(0x20))
    }

    func testRenderCellSGRComposesAllAttributes() {
        let cell = RenderCell(
            codepoint: UInt32(UInt8(ascii: "X")),
            bold: true, dim: true, italic: true, underline: .single,
            blink: true, inverse: true, invisible: true, strikethrough: true, overline: true
        )
        XCTAssertEqual(cell.sgr, "\u{1b}[0;1;2;3;4;5;7;8;9;53m")
    }

    func testResizeForcesFullRepaint() {
        let comp = GridCompositor(cols: 80, rows: 24)
        let grid = snapshot(80, 24, "Hello")
        _ = comp.render(panes: [pane(0, 0, 80, 24, grid)])
        comp.resize(cols: 100, rows: 30)
        let grid2 = snapshot(100, 30, "Hello")
        let out = comp.render(panes: [pane(0, 0, 100, 30, grid2)])
        XCTAssertTrue(out.contains("Hello"), "after resize the full frame repaints")
        XCTAssertTrue(out.contains("\u{1b}[2J"), "resize should trigger a clear + full repaint")
    }
}
