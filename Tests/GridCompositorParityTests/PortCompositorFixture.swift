// PORT side of the GridCompositor drift canary. Imports ONLY HarnessOnboarding so every
// unqualified type name resolves to the onboarding-preview port's inlined models / compositor
// — no collision with the live stack (built in LiveCompositorFixture.swift). Builds the SAME
// documented fixture (CompositorFixtureSpec); the test compares the two emitted ANSI strings.
//
// Twin: LiveCompositorFixture.swift — keep both fixtures in lockstep.
import Foundation
import HarnessOnboarding

enum PortCompositorFixture {
    private static func grid(_ first: String, cols: Int, rows: Int, cursorVisible: Bool) -> TerminalGridSnapshot {
        var cells = [TerminalGridCell](repeating: TerminalGridCell(codepoint: 0x20), count: cols * rows)
        for (i, scalar) in first.unicodeScalars.enumerated() where i < cols {
            cells[i] = TerminalGridCell(codepoint: scalar.value)
        }
        return TerminalGridSnapshot(
            cols: cols, rows: rows, cells: cells,
            cursor: TerminalCursor(row: 0, col: 0, visible: cursorVisible))
    }

    static func twoPaneWithStatus() -> String {
        let spec = CompositorFixtureSpec.self
        let left = CompositorPane(
            rect: PaneRect(paneID: UUID(), surfaceID: UUID(),
                           x: spec.leftRect.x, y: spec.leftRect.y, cols: spec.leftRect.cols, rows: spec.leftRect.rows),
            grid: grid("AB", cols: spec.leftRect.cols, rows: spec.leftRect.rows, cursorVisible: true),
            isActive: false)
        let right = CompositorPane(
            rect: PaneRect(paneID: UUID(), surfaceID: UUID(),
                           x: spec.rightRect.x, y: spec.rightRect.y, cols: spec.rightRect.cols, rows: spec.rightRect.rows),
            grid: grid("XY", cols: spec.rightRect.cols, rows: spec.rightRect.rows, cursorVisible: true),
            isActive: true)
        let status: [StyledSegment] = [
            StyledSegment(text: spec.statusText, bold: true),
            StyledSegment(text: spec.statusPlain),
        ]
        return GridCompositor(cols: spec.cols, rows: spec.rows)
            .render(panes: [left, right], statusLines: [status])
    }

    static func borderJunction() -> String {
        func blank(cols: Int, rows: Int) -> TerminalGridSnapshot {
            TerminalGridSnapshot(
                cols: cols, rows: rows,
                cells: [TerminalGridCell](repeating: TerminalGridCell(codepoint: 0x20), count: cols * rows),
                cursor: TerminalCursor(visible: false))
        }
        let panes: [CompositorPane] = [
            CompositorPane(
                rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: 0, y: 0, cols: 9, rows: 8),
                grid: blank(cols: 9, rows: 8), isActive: false),
            CompositorPane(
                rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: 10, y: 0, cols: 10, rows: 3),
                grid: blank(cols: 10, rows: 3), isActive: false),
            CompositorPane(
                rect: PaneRect(paneID: UUID(), surfaceID: UUID(), x: 10, y: 4, cols: 10, rows: 4),
                grid: blank(cols: 10, rows: 4), isActive: false),
        ]
        return GridCompositor(cols: 20, rows: 8).render(panes: panes, statusLines: nil)
    }
}
