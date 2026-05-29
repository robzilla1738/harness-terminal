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
