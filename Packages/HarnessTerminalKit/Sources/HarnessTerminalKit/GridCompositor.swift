import Foundation
import HarnessCopyMode
import HarnessCore
import HarnessTerminalEngine

/// One pane to composite: where it sits (`rect`, in the pane area) and its
/// current screen contents (`grid`). `isActive` selects the highlighted border
/// and where the real cursor is placed. The copy-mode fields, when set, overlay a
/// selection / search-hit highlight and place the copy-mode cursor — the same
/// `CopyModeState` projection the GUI overlay uses, so both surfaces agree.
public struct CompositorPane: Sendable {
    public var rect: PaneRect
    public var grid: TerminalGridSnapshot
    public var isActive: Bool
    /// Copy-mode selection in viewport coordinates (nil = none).
    public var selection: CopyModeViewportSelection?
    /// Copy-mode search hits, `line` rebased to a viewport row.
    public var searchHits: [CopyModeMatch]
    /// Copy-mode cursor in viewport coordinates (overrides the program cursor).
    public var copyModeCursor: (row: Int, column: Int)?

    public init(
        rect: PaneRect,
        grid: TerminalGridSnapshot,
        isActive: Bool,
        selection: CopyModeViewportSelection? = nil,
        searchHits: [CopyModeMatch] = [],
        copyModeCursor: (row: Int, column: Int)? = nil
    ) {
        self.rect = rect
        self.grid = grid
        self.isActive = isActive
        self.selection = selection
        self.searchHits = searchHits
        self.copyModeCursor = copyModeCursor
    }
}

/// Composites multiple pane grids into a single ANSI frame for a plain terminal
/// — the core of the `harness attach` renderer. It builds a `cols x rows` cell
/// buffer (panes + box-drawing borders + a status row), then emits the minimal
/// ANSI to transform the previously emitted frame into the new one (back-buffer
/// diff, for low bandwidth over ssh).
///
/// Pure and deterministic: feed it panes + a status line, get back a byte string
/// to write to the TTY. No I/O of its own.
public final class GridCompositor {
    public private(set) var cols: Int
    public private(set) var rows: Int

    /// The last emitted frame, for diffing. `nil` until the first render or
    /// after `invalidate()` (which forces a full repaint).
    private var front: [RenderCell]?

    public init(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
    }

    /// Resize the frame. Forces a full repaint on the next render.
    public func resize(cols: Int, rows: Int) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        front = nil
    }

    /// Drop the diff cache so the next render emits a full frame (e.g. after the
    /// outer terminal was cleared or resized underneath us).
    public func invalidate() { front = nil }

    /// Render `panes` plus an optional `status` line (drawn on the bottom row)
    /// into ANSI. Pane rects are expected to be laid out within the top
    /// `rows - (status == nil ? 0 : 1)` rows.
    public func render(panes: [CompositorPane], status: String? = nil, statusSegments: [StyledSegment]? = nil) -> String {
        let hasStatus = status != nil || statusSegments != nil
        let statusRow: Int? = hasStatus ? rows - 1 : nil
        var buffer = [RenderCell](repeating: .blank, count: cols * rows)

        // 1) Borders: fill the pane area with box-drawing lines, then panes
        //    paint their interiors over them. We classify each pane-area cell by
        //    whether it is covered by a pane; uncovered cells become borders.
        let paneArea = statusRow ?? rows
        paintBorders(into: &buffer, panes: panes, paneAreaRows: paneArea)

        // 2) Panes.
        var cursor: (x: Int, y: Int)? = nil
        for pane in panes {
            paint(pane: pane, into: &buffer, into: &cursor)
        }

        // 3) Status line — styled segments (with `#[…]` spans) take precedence over plain.
        if let statusRow {
            if let statusSegments {
                paintStatusSegments(statusSegments, row: statusRow, into: &buffer)
            } else if let status {
                paintStatus(status, row: statusRow, into: &buffer)
            }
        }

        // 4) Emit a diff (or full frame) and position the real cursor.
        let ansi = emit(buffer: buffer, cursor: cursor)
        front = buffer
        return ansi
    }

    // MARK: - Painting

    private func paint(
        pane: CompositorPane,
        into buffer: inout [RenderCell],
        into cursor: inout (x: Int, y: Int)?
    ) {
        let rect = pane.rect
        let grid = pane.grid
        let maxRows = min(rect.rows, grid.rows)
        let maxCols = min(rect.cols, grid.cols)
        for gy in 0 ..< maxRows {
            let by = rect.y + gy
            guard by >= 0, by < rows else { continue }
            for gx in 0 ..< maxCols {
                let bx = rect.x + gx
                guard bx >= 0, bx < cols else { continue }
                guard let cell = grid.cell(row: gy, col: gx) else { continue }
                // Skip the spacer that follows a wide character: the wide glyph
                // already spans two columns when emitted.
                if cell.width == .spacerTail { continue }
                var rc = RenderCell(cell)
                // Copy-mode shading (palette indices, so the client terminal themes them):
                // primary selection > search hit > normal.
                if pane.selection?.contains(row: gy, column: gx) == true {
                    rc.bg = Self.selectionBg; rc.fg = Self.selectionFg
                } else if pane.searchHits.contains(where: { $0.line == gy && gx >= $0.startColumn && gx < $0.endColumn }) {
                    rc.bg = Self.searchBg; rc.fg = Self.searchFg
                }
                buffer[by * cols + bx] = rc
            }
        }

        if pane.isActive {
            // The copy-mode cursor overrides the (hidden) program cursor while active.
            if let cm = pane.copyModeCursor {
                let cx = rect.x + cm.column, cy = rect.y + cm.row
                if cx >= 0, cx < cols, cy >= 0, cy < rows { cursor = (cx, cy) }
            } else if grid.cursor.visible {
                let cx = rect.x + grid.cursor.col
                let cy = rect.y + grid.cursor.row
                if cx >= 0, cx < cols, cy >= 0, cy < rows { cursor = (cx, cy) }
            }
        }
    }

    /// Copy-mode highlight palette (ANSI indices so the client's theme renders them):
    /// selection on blue, search hits on yellow.
    private static let selectionBg: TerminalGridColor = .palette(4)
    private static let selectionFg: TerminalGridColor = .palette(15)
    private static let searchBg: TerminalGridColor = .palette(3)
    private static let searchFg: TerminalGridColor = .palette(0)

    private func paintStatus(_ status: String, row: Int, into buffer: inout [RenderCell]) {
        var x = 0
        for scalar in status.unicodeScalars {
            guard x < cols else { break }
            buffer[row * cols + x] = RenderCell(codepoint: scalar.value, inverse: true)
            x += 1
        }
        while x < cols {
            buffer[row * cols + x] = RenderCell(codepoint: 0x20, inverse: true)
            x += 1
        }
    }

    /// Paint styled status segments. A fully-default segment (no fg/bg/attrs) renders as the
    /// classic inverse status band; styled spans honor their `#[fg=…,bg=…,attrs]`.
    private func paintStatusSegments(_ segments: [StyledSegment], row: Int, into buffer: inout [RenderCell]) {
        var x = 0
        for seg in segments {
            let plain = seg.fg == nil && seg.bg == nil && !seg.bold && !seg.italic && !seg.underline && !seg.reverse && !seg.dim
            for scalar in seg.text.unicodeScalars {
                guard x < cols else { break }
                buffer[row * cols + x] = RenderCell(
                    codepoint: scalar.value,
                    fg: Self.gridColor(seg.fg),
                    bg: Self.gridColor(seg.bg),
                    bold: seg.bold,
                    dim: seg.dim,
                    italic: seg.italic,
                    underline: seg.underline ? .single : .none,
                    inverse: plain ? true : seg.reverse
                )
                x += 1
            }
            if x >= cols { break }
        }
        while x < cols {
            buffer[row * cols + x] = RenderCell(codepoint: 0x20, inverse: true)
            x += 1
        }
    }

    private static func gridColor(_ color: FormatColor?) -> TerminalGridColor {
        switch color {
        case nil, .some(.none): return .none
        case let .some(.palette(i)): return .palette(i)
        case let .some(.rgb(r, g, b)): return .rgb(r: r, g: g, b: b)
        }
    }

    /// Fill the pane area with box-drawing borders. A cell is a border if it is
    /// NOT covered by any pane interior; its glyph is chosen from which of its
    /// 4 neighbors are also borders (so junctions render as ┼ ├ ┤ ┬ ┴ etc).
    private func paintBorders(
        into buffer: inout [RenderCell],
        panes: [CompositorPane],
        paneAreaRows: Int
    ) {
        guard paneAreaRows > 0 else { return }
        // Coverage map: true where a pane interior sits.
        var covered = [Bool](repeating: false, count: cols * paneAreaRows)
        for pane in panes {
            let r = pane.rect
            for y in max(0, r.y) ..< min(paneAreaRows, r.y + r.rows) {
                for x in max(0, r.x) ..< min(cols, r.x + r.cols) {
                    covered[y * cols + x] = true
                }
            }
        }

        func isBorder(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < cols, y >= 0, y < paneAreaRows else { return false }
            return !covered[y * cols + x]
        }

        for y in 0 ..< paneAreaRows {
            for x in 0 ..< cols where isBorder(x, y) {
                let up = isBorder(x, y - 1)
                let down = isBorder(x, y + 1)
                let left = isBorder(x - 1, y)
                let right = isBorder(x + 1, y)
                buffer[y * cols + x] = RenderCell(
                    codepoint: boxGlyph(up: up, down: down, left: left, right: right),
                    fg: .palette(8) // dim grey divider
                )
            }
        }
    }

    private func boxGlyph(up: Bool, down: Bool, left: Bool, right: Bool) -> UInt32 {
        switch (up, down, left, right) {
        case (true, true, true, true): return 0x253C   // ┼
        case (true, true, true, false): return 0x2524  // ┤
        case (true, true, false, true): return 0x251C  // ├
        case (true, true, false, false): return 0x2502 // │
        case (false, true, true, true): return 0x252C  // ┬
        case (true, false, true, true): return 0x2534  // ┴
        case (true, false, true, false): return 0x2518 // ┘
        case (true, false, false, true): return 0x2514 // └
        case (false, true, true, false): return 0x2510 // ┐
        case (false, true, false, true): return 0x250C // ┌
        case (false, false, true, true): return 0x2500 // ─
        case (true, false, false, false), (false, true, false, false): return 0x2502 // │
        case (false, false, true, false), (false, false, false, true): return 0x2500 // ─
        default: return 0x2502
        }
    }

    // MARK: - ANSI emission

    private func emit(buffer: [RenderCell], cursor: (x: Int, y: Int)?) -> String {
        var out = ""
        out += "\u{1b}[?25l" // hide cursor while painting

        let full = front == nil || front?.count != buffer.count
        if full {
            out += "\u{1b}[2J" // clear on full repaint
        }

        var lastSGR = ""
        var penX = -1
        var penY = -1
        for y in 0 ..< rows {
            for x in 0 ..< cols {
                let idx = y * cols + x
                let cell = buffer[idx]
                if !full, let front, front[idx] == cell { continue }

                // Move the cursor only when not already in place.
                if penY != y || penX != x {
                    out += "\u{1b}[\(y + 1);\(x + 1)H"
                }
                let sgr = cell.sgr
                if sgr != lastSGR {
                    out += sgr
                    lastSGR = sgr
                }
                out.unicodeScalars.append(cell.scalar)
                penX = x + 1
                penY = y
            }
        }

        out += "\u{1b}[0m" // reset attributes

        if let cursor {
            out += "\u{1b}[\(cursor.y + 1);\(cursor.x + 1)H"
            out += "\u{1b}[?25h" // show cursor at the active pane
        }
        return out
    }
}

// MARK: - RenderCell

/// A flattened cell in the composited frame: a glyph plus the subset of SGR
/// state we re-emit. `Equatable` drives the back-buffer diff.
struct RenderCell: Equatable {
    var codepoint: UInt32
    var fg: TerminalGridColor
    var bg: TerminalGridColor
    var underlineColor: TerminalGridColor
    var bold: Bool
    var dim: Bool
    var italic: Bool
    var underline: TerminalGridUnderline
    var blink: Bool
    var inverse: Bool
    var invisible: Bool
    var strikethrough: Bool
    var overline: Bool

    init(
        codepoint: UInt32,
        fg: TerminalGridColor = .none,
        bg: TerminalGridColor = .none,
        underlineColor: TerminalGridColor = .none,
        bold: Bool = false,
        dim: Bool = false,
        italic: Bool = false,
        underline: TerminalGridUnderline = .none,
        blink: Bool = false,
        inverse: Bool = false,
        invisible: Bool = false,
        strikethrough: Bool = false,
        overline: Bool = false
    ) {
        self.codepoint = codepoint
        self.fg = fg
        self.bg = bg
        self.underlineColor = underlineColor
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
        self.blink = blink
        self.inverse = inverse
        self.invisible = invisible
        self.strikethrough = strikethrough
        self.overline = overline
    }

    init(_ c: TerminalGridCell) {
        codepoint = c.codepoint
        fg = c.foreground
        bg = c.background
        underlineColor = c.underlineColor
        bold = c.bold
        dim = c.faint
        italic = c.italic
        underline = c.underline
        blink = c.blink
        inverse = c.inverse
        invisible = c.invisible
        strikethrough = c.strikethrough
        overline = c.overline
    }

    static let blank = RenderCell(codepoint: 0x20)

    /// A guaranteed-valid space scalar; the single audited force-unwrap (U+0020 is
    /// always a valid scalar) used as the fallback glyph for empty/invalid cells.
    private static let space = Unicode.Scalar(0x20)!

    /// The glyph to draw (empty cells render as a space).
    var scalar: Unicode.Scalar {
        guard codepoint != 0, let s = Unicode.Scalar(codepoint) else { return Self.space }
        return s
    }

    /// The SGR sequence that establishes this cell's attributes. Always starts
    /// from a reset so it is self-contained (no dependence on prior pen state),
    /// which keeps the diff emitter correct when it skips unchanged cells.
    var sgr: String {
        var codes: [String] = ["0"]
        if bold { codes.append("1") }
        if dim { codes.append("2") }
        if italic { codes.append("3") }
        codes.append(contentsOf: Self.underlineCodes(underline))
        if blink { codes.append("5") }
        if inverse { codes.append("7") }
        if invisible { codes.append("8") }
        if strikethrough { codes.append("9") }
        if overline { codes.append("53") }
        codes.append(contentsOf: Self.colorCodes(fg, kind: .fg))
        codes.append(contentsOf: Self.colorCodes(bg, kind: .bg))
        if underline != .none {
            codes.append(contentsOf: Self.colorCodes(underlineColor, kind: .underline))
        }
        return "\u{1b}[\(codes.joined(separator: ";"))m"
    }

    /// SGR underline-style codes. Single is the classic `4`; double is `21`; the
    /// curly/dotted/dashed styles use the `4:N` substyle form modern terminals
    /// (mainstream terminals) understand.
    private static func underlineCodes(_ style: TerminalGridUnderline) -> [String] {
        switch style {
        case .none: return []
        case .single: return ["4"]
        case .double: return ["21"]
        case .curly: return ["4:3"]
        case .dotted: return ["4:4"]
        case .dashed: return ["4:5"]
        }
    }

    private enum ColorKind {
        case fg, bg, underline
        var base: Int {
            switch self {
            case .fg: return 38
            case .bg: return 48
            case .underline: return 58
            }
        }
    }

    private static func colorCodes(_ color: TerminalGridColor, kind: ColorKind) -> [String] {
        switch color {
        case .none:
            return []
        case let .palette(idx):
            return ["\(kind.base)", "5", "\(idx)"]
        case let .rgb(r, g, b):
            return ["\(kind.base)", "2", "\(r)", "\(g)", "\(b)"]
        }
    }
}
