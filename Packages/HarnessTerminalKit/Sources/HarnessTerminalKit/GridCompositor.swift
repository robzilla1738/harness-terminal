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
    /// `window-style`/`pane-style` base colors for this pane's default-colored cells
    /// (dim inactive panes). `.none` = no override. Applied before copy-mode shading so a
    /// selection/search hit still wins.
    public var baseForeground: TerminalGridColor
    public var baseBackground: TerminalGridColor
    /// `pane-border-format` label drawn on this pane's border row (`rect.labelRow`), centered
    /// over the box-drawing. Active panes draw it highlighted. Nil/empty = no label.
    public var borderLabel: String?

    public init(
        rect: PaneRect,
        grid: TerminalGridSnapshot,
        isActive: Bool,
        selection: CopyModeViewportSelection? = nil,
        searchHits: [CopyModeMatch] = [],
        copyModeCursor: (row: Int, column: Int)? = nil,
        baseForeground: TerminalGridColor = .none,
        baseBackground: TerminalGridColor = .none,
        borderLabel: String? = nil
    ) {
        self.rect = rect
        self.grid = grid
        self.isActive = isActive
        self.selection = selection
        self.searchHits = searchHits
        self.copyModeCursor = copyModeCursor
        self.baseForeground = baseForeground
        self.baseBackground = baseBackground
        self.borderLabel = borderLabel
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
    /// into ANSI. Convenience over `render(panes:statusLines:)` for the single-line
    /// case: styled segments (with `#[…]` spans) take precedence over a plain string.
    public func render(
        panes: [CompositorPane],
        status: String? = nil,
        statusSegments: [StyledSegment]? = nil,
        statusPosition: StatusPosition = .bottom
    ) -> String {
        let lines: [[StyledSegment]]?
        if let statusSegments {
            lines = [statusSegments]
        } else if let status {
            // A plain string is one fully-default segment → the classic inverse band.
            lines = [[StyledSegment(text: status)]]
        } else {
            lines = nil
        }
        return render(panes: panes, statusLines: lines, statusPosition: statusPosition)
    }

    /// Render `panes` plus N status lines (tmux `status 2..5`). `statusLines` is
    /// **band-relative from the main line outward**: index 0 is the main line, index 1 the
    /// next row, and so on. With `statusPosition == .bottom` the main line is the last row
    /// and extras stack upward; with `.top` the main line is row 0 and extras stack downward.
    /// The pane area is the complementary `rows - statusLines.count` rows — the caller must
    /// have solved its pane rects with a matching `yOrigin` (0 for bottom, `statusCount` for
    /// top) so panes/borders never overlap the band. `nil`/empty hides the status entirely.
    public func render(
        panes: [CompositorPane],
        statusLines: [[StyledSegment]]?,
        statusPosition: StatusPosition = .bottom
    ) -> String {
        let statusCount = max(0, min(rows, statusLines?.count ?? 0))
        var buffer = [RenderCell](repeating: .blank, count: cols * rows)

        // 1) Borders: fill the pane area with box-drawing lines, then panes
        //    paint their interiors over them. We classify each pane-area cell by
        //    whether it is covered by a pane; uncovered cells become borders.
        //    The pane area is the band complementary to the status rows: it starts
        //    below the band for a top status line, or at row 0 for a bottom one.
        let paneArea = rows - statusCount
        let paneAreaY0 = statusPosition == .top ? statusCount : 0
        paintBorders(into: &buffer, panes: panes, paneAreaY0: paneAreaY0, paneAreaRows: paneArea)

        // 2) Panes (rects already absolute, including the `yOrigin` reservation).
        var cursor: (x: Int, y: Int)? = nil
        for pane in panes {
            paint(pane: pane, into: &buffer, into: &cursor)
        }

        // 2.5) `pane-border-status` labels, drawn over the border row carved for each pane.
        for pane in panes {
            guard let label = pane.borderLabel, !label.isEmpty, let row = pane.rect.labelRow else { continue }
            paintBorderLabel(label, row: row, paneX: pane.rect.x, paneCols: pane.rect.cols, active: pane.isActive, into: &buffer)
        }

        // 3) Status lines from the main line outward: at the bottom, line i sits on row
        //    `rows - 1 - i` (stack upward); at the top, line i sits on row `i` (stack downward).
        if let statusLines {
            for (i, line) in statusLines.prefix(statusCount).enumerated() {
                let row = statusPosition == .top ? i : rows - 1 - i
                paintStatusSegments(line, row: row, into: &buffer)
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
                // `window-style`/`pane-style` base: substitute the pane's base color into any
                // cell still using the surface default, so an inactive pane dims uniformly.
                if pane.baseForeground != .none, rc.fg == .none { rc.fg = pane.baseForeground }
                if pane.baseBackground != .none, rc.bg == .none { rc.bg = pane.baseBackground }
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

    /// Draw a `pane-border-format` label centered on `row` within the pane's column span,
    /// over the box-drawing border. The active pane's label is highlighted (bold, brighter)
    /// so the focused pane stands out, matching tmux's pane-active-border accent.
    private func paintBorderLabel(_ text: String, row: Int, paneX: Int, paneCols: Int, active: Bool, into buffer: inout [RenderCell]) {
        guard row >= 0, row < rows, paneCols > 0 else { return }
        // Center + place by DISPLAY width, not scalar count: a wide glyph occupies two cells and a
        // combining mark zero, so counting scalars mis-centered and over-truncated non-ASCII labels.
        // (For an all-ASCII label every width is 1, so this is identical to the old scalar loop.)
        let scalars = Array(text.unicodeScalars)
        let displayWidth = scalars.reduce(0) { $0 + CharacterWidth.width(of: $1) }
        let width = min(displayWidth, paneCols)
        guard width > 0 else { return }
        let fg: TerminalGridColor = active ? .palette(15) : .palette(8)
        let limit = min(cols, paneX + paneCols)
        var x = paneX + max(0, (paneCols - width) / 2)
        var lastBaseIdx: Int? = nil
        for scalar in scalars {
            let w = CharacterWidth.width(of: scalar)
            if w == 0 {
                // Combining mark — fold onto the label's preceding base cell rather than drop it.
                if let bi = lastBaseIdx {
                    if buffer[bi].combining0 == 0 { buffer[bi].combining0 = scalar.value }
                    else if buffer[bi].combining1 == 0 { buffer[bi].combining1 = scalar.value }
                }
                continue
            }
            guard x >= 0, x + w <= limit else { break }
            let idx = row * cols + x
            buffer[idx] = RenderCell(codepoint: scalar.value, fg: fg, bold: active)
            // Blank a wide glyph's continuation cell so the border char beneath it doesn't show.
            if w == 2, x + 1 < limit { buffer[row * cols + x + 1] = RenderCell(codepoint: 0x20, fg: fg, bold: active) }
            lastBaseIdx = idx
            x += w
        }
    }

    /// Map a renderer-agnostic `FormatColor` to the engine's `TerminalGridColor`, preserving
    /// palette indices (so the client terminal's own theme colors them). Shared by status
    /// segments and `window-style`/`pane-style` base colors.
    public static func gridColor(_ color: FormatColor?) -> TerminalGridColor {
        switch color {
        case nil, .some(.none): return .none
        case let .some(.palette(i)): return .palette(UInt8(clamping: i))
        case let .some(.rgb(r, g, b)): return .rgb(r: r, g: g, b: b)
        }
    }

    /// Fill the pane area with box-drawing borders. A cell is a border if it is
    /// NOT covered by any pane interior; its glyph is chosen from which of its
    /// 4 neighbors are also borders (so junctions render as ┼ ├ ┤ ┬ ┴ etc).
    private func paintBorders(
        into buffer: inout [RenderCell],
        panes: [CompositorPane],
        paneAreaY0: Int,
        paneAreaRows: Int
    ) {
        guard paneAreaRows > 0 else { return }
        let y1 = paneAreaY0 + paneAreaRows
        // Coverage map (whole-frame so we can index absolute rows): true where a pane interior sits.
        var covered = [Bool](repeating: false, count: cols * rows)
        for pane in panes {
            let r = pane.rect
            for y in max(paneAreaY0, r.y) ..< min(y1, r.y + r.rows) {
                for x in max(0, r.x) ..< min(cols, r.x + r.cols) {
                    covered[y * cols + x] = true
                }
            }
        }

        // A cell is a border only inside the pane-area band and not covered by a pane.
        func isBorder(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < cols, y >= paneAreaY0, y < y1 else { return false }
            return !covered[y * cols + x]
        }

        for y in paneAreaY0 ..< y1 {
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
                out += cell.cluster // base + combining marks (one display column)
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
    /// Stacked combining scalars (0 = none), carried so a remote pane's Thai vowels/tones (and
    /// pane-label marks) are re-emitted to the client terminal instead of dropped. Part of
    /// `Equatable` so a combining-only change still repaints in the diff emitter.
    var combining0: UInt32 = 0
    var combining1: UInt32 = 0
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
        combining0: UInt32 = 0,
        combining1: UInt32 = 0,
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
        self.combining0 = combining0
        self.combining1 = combining1
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
        combining0 = c.combining0
        combining1 = c.combining1
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

    /// The full grapheme to emit: base scalar plus any combining marks. Empty cells render as a
    /// space. A no-mark cell yields a single scalar, so ASCII/CJK output is byte-identical.
    var cluster: String {
        guard codepoint != 0, let base = Unicode.Scalar(codepoint) else { return " " }
        var s = String()
        s.unicodeScalars.append(base)
        if combining0 != 0, let m = Unicode.Scalar(combining0) { s.unicodeScalars.append(m) }
        if combining1 != 0, let m = Unicode.Scalar(combining1) { s.unicodeScalars.append(m) }
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
