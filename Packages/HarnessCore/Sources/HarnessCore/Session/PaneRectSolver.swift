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
    /// Absolute row for this pane's `pane-border-status` label (carved from the pane's top
    /// or bottom), or nil when `pane-border-status off`. The interior (`x/y/cols/rows`)
    /// already excludes it, so the pane's surface is sized one row shorter (tmux behavior).
    public var labelRow: Int?

    public init(paneID: PaneID, surfaceID: SurfaceID, x: Int, y: Int, cols: Int, rows: Int, labelRow: Int? = nil) {
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.x = x
        self.y = y
        self.cols = cols
        self.rows = rows
        self.labelRow = labelRow
    }
}

/// Where (if anywhere) each pane shows its `pane-border-format` label.
public enum PaneBorderStatus: String, Sendable, Equatable {
    case off, top, bottom

    public init(option value: String) {
        self = PaneBorderStatus(rawValue: value.lowercased()) ?? .off
    }
}

/// Which window edge the `status` band occupies (tmux `status-position`). The pane
/// area is the complementary band; the GUI status footer and the `attach` compositor
/// both anchor off this so the layout matches end-to-end.
public enum StatusPosition: String, Sendable, Equatable {
    case bottom, top

    public init(option value: String) {
        self = StatusPosition(rawValue: value.lowercased()) ?? .bottom
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
    ///
    /// `yOrigin` shifts every produced rect (interior `y` and `labelRow`) down by that
    /// many rows so the caller can reserve a top status band: pass `0` for a bottom status
    /// line (pane area starts at row 0) or the status row count for a top status line (pane
    /// area starts below the band). Coordinates stay absolute end-to-end — the compositor
    /// consumes them as-is.
    public static func solve(
        _ node: PaneNode,
        cols: Int,
        rows: Int,
        border: Bool = true,
        paneBorderStatus: PaneBorderStatus = .off,
        yOrigin: Int = 0
    ) -> [PaneRect] {
        guard cols > 0, rows > 0 else { return [] }
        var out: [PaneRect] = []
        solve(node, x: 0, y: yOrigin, cols: cols, rows: rows, border: border, status: paneBorderStatus, into: &out)
        return out
    }

    private static func solve(
        _ node: PaneNode,
        x: Int,
        y: Int,
        cols: Int,
        rows: Int,
        border: Bool,
        status: PaneBorderStatus,
        into out: inout [PaneRect]
    ) {
        guard cols > 0, rows > 0 else { return }

        // A zero-size region (e.g. a split forced into < 2 cells) yields no pane — never a broken
        // 0-row/0-col rect that downstream rendering would choke on or silently drop.
        guard rows > 0, cols > 0 else { return }
        switch node {
        case let .leaf(leaf):
            // Carve one row for the border-status label (only if the pane keeps >= 1 content
            // row); the interior shrinks so the pane's surface is sized to match.
            var iy = y, irows = rows, labelRow: Int? = nil
            if status != .off, rows >= 2 {
                switch status {
                case .top: labelRow = y; iy = y + 1; irows = rows - 1
                case .bottom: labelRow = y + rows - 1; irows = rows - 1
                case .off: break
                }
            }
            out.append(PaneRect(
                paneID: leaf.id,
                surfaceID: leaf.surfaceID,
                x: x, y: iy, cols: cols, rows: irows, labelRow: labelRow
            ))

        case let .branch(direction, ratio, first, second):
            switch direction {
            case .horizontal:
                // Side-by-side: split along columns.
                let (firstCols, gap, secondCols) = split(total: cols, ratio: ratio, border: border)
                solve(first, x: x, y: y, cols: firstCols, rows: rows, border: border, status: status, into: &out)
                solve(second, x: x + firstCols + gap, y: y, cols: secondCols, rows: rows, border: border, status: status, into: &out)

            case .vertical:
                // Stacked: split along rows.
                let (firstRows, gap, secondRows) = split(total: rows, ratio: ratio, border: border)
                solve(first, x: x, y: y, cols: cols, rows: firstRows, border: border, status: status, into: &out)
                solve(second, x: x, y: y + firstRows + gap, cols: cols, rows: secondRows, border: border, status: status, into: &out)
            }
        }
    }

    /// Split `total` cells into (first, gap, second) where `gap` is the divider
    /// (0 or 1). Both children get at least 1 cell; the divider is dropped if
    /// there isn't room for it plus a cell on each side.
    private static func split(total: Int, ratio: Double, border: Bool) -> (Int, Int, Int) {
        let wantGap = border && total >= 3
        let gap = wantGap ? 1 : 0
        let available = max(0, total - gap)
        let r = ratio.isFinite ? min(max(ratio, 0), 1) : 0.5
        // Fewer than 2 cells to share: two panes can't both get one. Give the first what's left and
        // leave the second at 0 — solve() drops a zero-size child rather than emit a broken rect.
        // (The old clamp `max(available - 1, 1)` forced first = 1, second = 0 here, but then still
        // produced that 0-row/col rect downstream.)
        guard available >= 2 else { return (available, gap, 0) }
        var first = Int((Double(available) * r).rounded())
        first = min(max(first, 1), available - 1) // both sides keep >= 1
        return (first, gap, available - first)
    }
}
