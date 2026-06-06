// LIVE side of the GridCompositor drift canary. Imports only the live stack
// (HarnessTerminalKit + the real HarnessCore/HarnessTerminalEngine models) so every
// unqualified type name resolves to the production compositor — no module/type-name
// collisions with the onboarding port (built in PortCompositorFixture.swift). The two
// files build the SAME documented fixture (see CompositorFixtureSpec) and the test in
// GridCompositorParityTests.swift compares their emitted ANSI byte-for-byte.
//
// Twin: PortCompositorFixture.swift — keep both fixtures in lockstep.
import Foundation
import HarnessCore
import HarnessTerminalEngine
import HarnessTerminalKit

enum LiveCompositorFixture {
    private static func grid(_ first: String, cols: Int, rows: Int, cursorVisible: Bool) -> TerminalGridSnapshot {
        var cells = [TerminalGridCell](repeating: TerminalGridCell(codepoint: 0x20), count: cols * rows)
        for (i, scalar) in first.unicodeScalars.enumerated() where i < cols {
            cells[i] = TerminalGridCell(codepoint: scalar.value)
        }
        return TerminalGridSnapshot(
            cols: cols, rows: rows, cells: cells,
            cursor: TerminalCursor(row: 0, col: 0, visible: cursorVisible))
    }

    /// 2-pane horizontal split + vertical border + a styled/plain status line.
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

    /// Three panes whose dividers meet at a T/cross junction — exercises the box-glyph table.
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
