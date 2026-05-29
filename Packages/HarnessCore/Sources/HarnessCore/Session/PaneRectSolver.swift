import Foundation

/// The interior rectangle a single pane renders into, in terminal cell
/// coordinates (origin top-left, x = column, y = row). Excludes the 1-cell
/// dividers drawn between panes.
public struct PaneRect: Sendable, Equatable {
    public var paneID: PaneID
    public var surfaceID: SurfaceID
    public var x: Int
    public var y: Int
    public var cols: Int
    public var rows: Int

    public init(paneID: PaneID, surfaceID: SurfaceID, x: Int, y: Int, cols: Int, rows: Int) {
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.x = x
        self.y = y
        self.cols = cols
        self.rows = rows
    }
}

/// Computes pane interior rectangles from a `PaneNode` split tree for a content
/// area of `cols` x `rows` cells, reserving one cell between siblings for a
/// border. Shared by the `harness attach` compositor (and reusable by the GUI).
///
/// Geometry matches the GUI's NSSplitView mapping: a `.horizontal` branch is
/// side-by-side (first = left, second = right); a `.vertical` branch is stacked
/// (first = top, second = bottom). `ratio` is the first child's fraction of the
/// split axis.
///
/// The caller is responsible for reserving any status line (pass a `rows` that
/// already excludes it). Dividers are the 1-cell gaps left between rects; a
/// compositor can simply fill the whole area with a border glyph and paint the
/// returned interiors on top.
public enum PaneRectSolver {
    /// When a split has too little room for a 1-cell divider plus a 1-cell pane
    /// on each side, we drop the border for that split so both panes stay
    /// visible. `border` controls whether a divider cell is reserved at all.
    public static func solve(
        _ node: PaneNode,
        cols: Int,
        rows: Int,
        border: Bool = true
    ) -> [PaneRect] {
        guard cols > 0, rows > 0 else { return [] }
        var out: [PaneRect] = []
        solve(node, x: 0, y: 0, cols: cols, rows: rows, border: border, into: &out)
        return out
    }

    private static func solve(
        _ node: PaneNode,
        x: Int,
        y: Int,
        cols: Int,
        rows: Int,
        border: Bool,
        into out: inout [PaneRect]
    ) {
        guard cols > 0, rows > 0 else { return }

        switch node {
        case let .leaf(leaf):
            out.append(PaneRect(
                paneID: leaf.id,
                surfaceID: leaf.surfaceID,
                x: x, y: y, cols: cols, rows: rows
            ))

        case let .branch(direction, ratio, first, second):
            switch direction {
            case .horizontal:
                // Side-by-side: split along columns.
                let (firstCols, gap, secondCols) = split(total: cols, ratio: ratio, border: border)
                solve(first, x: x, y: y, cols: firstCols, rows: rows, border: border, into: &out)
                solve(second, x: x + firstCols + gap, y: y, cols: secondCols, rows: rows, border: border, into: &out)

            case .vertical:
                // Stacked: split along rows.
                let (firstRows, gap, secondRows) = split(total: rows, ratio: ratio, border: border)
                solve(first, x: x, y: y, cols: cols, rows: firstRows, border: border, into: &out)
                solve(second, x: x, y: y + firstRows + gap, cols: cols, rows: secondRows, border: border, into: &out)
            }
        }
    }

    /// Split `total` cells into (first, gap, second) where `gap` is the divider
    /// (0 or 1). Both children get at least 1 cell; the divider is dropped if
    /// there isn't room for it plus a cell on each side.
    private static func split(total: Int, ratio: Double, border: Bool) -> (Int, Int, Int) {
        let wantGap = border && total >= 3
        let gap = wantGap ? 1 : 0
        let available = total - gap
        // Clamp the first child to [1, available-1] so the second keeps >= 1.
        let r = ratio.isFinite ? min(max(ratio, 0), 1) : 0.5
        var first = Int((Double(available) * r).rounded())
        first = min(max(first, 1), max(available - 1, 1))
        let second = available - first
        return (first, gap, second)
    }
}
