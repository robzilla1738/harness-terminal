import HarnessCore
import HarnessTerminalEngine
import HarnessTheme

/// A color as normalized floats (0...1) — the form a Metal shader consumes. Built from
/// an `RGBColor` at the renderer boundary. Accurate mode is an sRGB identity mapping;
/// vivid mode converts authored sRGB into Display-P3 before the Metal layer is tagged P3.
public struct RenderColor: Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    public init(red: Float, green: Float, blue: Float, alpha: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `Float(i) / 255` for every 0...255 byte. `FrameBuilder.appendRow` calls `renderColor` ~3–5×
    /// per cell, so on a color-dense frame this replaces thousands of multi-cycle float divides per
    /// build with a load. The table is computed with the *identical* `Float(i) / 255` expression, so
    /// every produced value is bit-for-bit equal to the divide it replaces (no 1/255-reciprocal ULP
    /// drift) — the byte-identical-output invariant holds.
    static let byteToUnitFloat: [Float] = (0 ... 255).map { Float($0) / 255 }

    public init(_ c: RGBColor) {
        let lut = RenderColor.byteToUnitFloat
        self.init(
            red: lut[Int(c.red)],
            green: lut[Int(c.green)],
            blue: lut[Int(c.blue)],
            alpha: lut[Int(c.alpha)]
        )
    }

    /// RGB from the color, but with an explicit alpha (0...1) — used to make the
    /// translucent canvas background while keeping the color channels exact.
    public init(_ c: RGBColor, alpha: Float) {
        let lut = RenderColor.byteToUnitFloat
        self.init(
            red: lut[Int(c.red)],
            green: lut[Int(c.green)],
            blue: lut[Int(c.blue)],
            alpha: alpha
        )
    }
}

/// One drawable cell: final fg/bg/underline colors plus the glyph and the attributes the
/// renderer needs to *draw* (font face selection + decorations). Color-affecting
/// attributes (inverse/faint/conceal) are already baked into the resolved colors.
public struct RenderCell: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var codepoint: UInt32
    public var foreground: RenderColor
    public var background: RenderColor
    public var underlineColor: RenderColor
    public var bold: Bool
    public var italic: Bool
    public var underline: TerminalGridUnderline
    public var strikethrough: Bool
    public var overline: Bool
    public var width: TerminalCellWidth
    /// Whether the renderer must paint this cell's background quad. `false` for cells whose
    /// resolved background is the default canvas color (which the target is already cleared to),
    /// so the common case of plain text skips a redundant fill. `true` for explicit program
    /// backgrounds, inverse cells, selection, and search highlights. Defaults to `true` so any
    /// cell built without an explicit decision is still filled.
    public var drawBackground: Bool = true

    /// True when there is a visible glyph to rasterize (not blank/space and not the
    /// trailing spacer of a wide cell). The cell background is filled only when
    /// `drawBackground` is set.
    public var hasGlyph: Bool {
        guard width != .spacerTail else { return false }
        return codepoint != 0 && codepoint != 0x20
    }
}

/// A render-ready frame: the resolved background-pass + glyph-pass data for one grid
/// snapshot, plus the cursor. Pure value type — the Metal renderer turns this into draw
/// calls, and it is fully unit-testable without a GPU.
/// An inline image to draw over the grid. Carries the decoded pixels (for first-time GPU upload)
/// plus its cell rect + z. Equality intentionally ignores the pixels (the id uniquely identifies
/// them — ids are monotonic, never reused) so frame diffing stays cheap.
public struct FrameImage: Equatable, Sendable {
    public var id: Int
    public var column: Int
    public var row: Int
    public var columns: Int
    public var rows: Int
    public var z: Int
    public var image: DecodedImage

    public init(id: Int, column: Int, row: Int, columns: Int, rows: Int, z: Int, image: DecodedImage) {
        self.id = id; self.column = column; self.row = row
        self.columns = columns; self.rows = rows; self.z = z; self.image = image
    }

    public static func == (lhs: FrameImage, rhs: FrameImage) -> Bool {
        lhs.id == rhs.id && lhs.column == rhs.column && lhs.row == rhs.row
            && lhs.columns == rhs.columns && lhs.rows == rhs.rows && lhs.z == rhs.z
    }
}

public struct TerminalFrame: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    /// Row-major, `columns * rows` long — every grid position. The renderer clears the surface
    /// to the canvas color and fills a per-cell background quad only where `drawBackground` is
    /// set, so default-canvas cells rely on the clear rather than their own quad.
    public var cells: [RenderCell]
    public var cursor: CursorRender
    /// Inline images overlaid on the grid (empty when none).
    public var images: [FrameImage]
    /// OSC 133 prompt-gutter colors keyed by viewport row: the resolved stripe color to paint
    /// in the left margin of a shell-prompt row (green = exit 0, red = non-zero, neutral =
    /// prompt with no exit yet). Empty without shell integration, so the gutter is a no-op then.
    public var promptGutter: [Int: RenderColor]

    public init(columns: Int, rows: Int, cells: [RenderCell], cursor: CursorRender,
                images: [FrameImage] = [], promptGutter: [Int: RenderColor] = [:]) {
        self.columns = columns
        self.rows = rows
        self.cells = cells
        self.cursor = cursor
        self.images = images
        self.promptGutter = promptGutter
    }

    public func cell(row: Int, column: Int) -> RenderCell? {
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return cells[row * columns + column]
    }
}

/// Cursor shape, matching the `cursor-style` set.
public enum CursorStyle: String, Equatable, Sendable {
    case block
    case bar
    case underline
}

/// Where to draw the cursor and in what color (already resolved). `visible` follows the
/// terminal's DECTCEM state.
public struct CursorRender: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var visible: Bool
    public var color: RenderColor
    /// Color of the glyph sitting under a block cursor (for legibility), typically the
    /// theme cursor-text / canvas background.
    public var textColor: RenderColor
    public var style: CursorStyle
    /// Drawn as a 1px box outline (regardless of style) when the surface is unfocused, so an
    /// inactive window reads as such — standard macOS/Ghostty behavior. A hollow block also does
    /// NOT invert the glyph under it (the cell shows through the outline).
    public var hollow: Bool

    public init(
        row: Int,
        column: Int,
        visible: Bool,
        color: RenderColor,
        textColor: RenderColor,
        style: CursorStyle = .block,
        hollow: Bool = false
    ) {
        self.row = row
        self.column = column
        self.visible = visible
        self.color = color
        self.textColor = textColor
        self.style = style
        self.hollow = hollow
    }
}

private func renderCursorStyle(userStyle: CursorStyle, programShape: TerminalCursorShape) -> CursorStyle {
    switch programShape {
    case .default:
        return userStyle
    case .block:
        return .block
    case .bar:
        return .bar
    case .underline:
        return .underline
    }
}

/// A linear (line-wrapping) text selection over the grid, normalized so `start` is at or
/// before `end` in reading order. Bounds are inclusive cell coordinates.
public struct TerminalSelection: Equatable, Sendable {
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int

    /// Build a normalized selection from two arbitrary endpoints (anchor + head).
    public init(_ a: (row: Int, column: Int), _ b: (row: Int, column: Int)) {
        if (a.row, a.column) <= (b.row, b.column) {
            startRow = a.row; startColumn = a.column; endRow = b.row; endColumn = b.column
        } else {
            startRow = b.row; startColumn = b.column; endRow = a.row; endColumn = a.column
        }
    }

    /// Whether a cell is inside the linear selection (full intermediate rows).
    public func contains(row: Int, column: Int) -> Bool {
        if row < startRow || row > endRow { return false }
        if startRow == endRow { return column >= startColumn && column <= endColumn }
        if row == startRow { return column >= startColumn }
        if row == endRow { return column <= endColumn }
        return true
    }
}

/// A rectangle (block / column) selection: every cell within the row AND column bounds, as
/// opposed to a linear selection's full intermediate rows. Used by copy-mode `C-v`.
public struct BlockSelection: Equatable, Sendable {
    public var startRow: Int
    public var startColumn: Int
    public var endRow: Int
    public var endColumn: Int

    /// Normalized from two arbitrary corners (inclusive bounds).
    public init(_ a: (row: Int, column: Int), _ b: (row: Int, column: Int)) {
        startRow = min(a.row, b.row); endRow = max(a.row, b.row)
        startColumn = min(a.column, b.column); endColumn = max(a.column, b.column)
    }

    public func contains(row: Int, column: Int) -> Bool {
        row >= startRow && row <= endRow && column >= startColumn && column <= endColumn
    }
}

/// A selection region — either line-wrapping (`linear`) or rectangular (`block`). Lets the
/// renderer apply one selection-shading path to both, instead of special-casing rectangle.
public enum SelectionRegion: Equatable, Sendable {
    case linear(TerminalSelection)
    case block(BlockSelection)

    public func contains(row: Int, column: Int) -> Bool {
        switch self {
        case let .linear(s): return s.contains(row: row, column: column)
        case let .block(b): return b.contains(row: row, column: column)
        }
    }
}

/// Turns an engine `TerminalGridSnapshot` into a `TerminalFrame` by resolving every
/// cell's colors through a `CellColorResolver`. This is the single bridge between the
/// headless engine and the GPU renderer — keeping it pure means the renderer never has
/// to know about palettes, defaults, or attribute rules.
public struct FrameBuilder {
    public let resolver: CellColorResolver
    /// Cursor block color (typically the theme cursor color).
    public let cursorColor: RGBColor
    /// Color for the glyph under a block cursor (cursor-text); defaults to the canvas bg.
    public let cursorTextColor: RGBColor
    /// Alpha (0...1) applied to cells drawn with the *default* (canvas) background, so the
    /// canvas can be translucent (showing the window blur) while program output stays
    /// readable. Cells with an explicit program background — and any glyph/cursor — remain
    /// fully opaque. 1 = fully opaque canvas (no translucency).
    public let canvasOpacity: Float
    /// Cursor shape drawn at the cursor cell.
    public let cursorStyle: CursorStyle
    /// Highlight colors for selected cells. Background nil = no highlight; foreground nil =
    /// keep each cell's own foreground.
    public let selectionBackground: RGBColor?
    public let selectionForeground: RGBColor?
    /// Highlight colors for copy-mode search hits (cells matched by the active query that are
    /// not also inside the primary selection). Background nil = no search highlight.
    public let searchBackground: RGBColor?
    public let searchForeground: RGBColor?
    /// Draw the OSC 133 prompt gutter (the per-row success/failure stripe). Defaults to `true`
    /// so existing callers/tests are unchanged; the GUI passes the user's `showPromptGutter`
    /// setting (off by default), so the stripe only renders when a user opts in.
    public let promptGutterEnabled: Bool
    private let colorConverter: RenderColorConverter

    public init(
        resolver: CellColorResolver,
        cursorColor: RGBColor,
        cursorTextColor: RGBColor? = nil,
        canvasOpacity: Float = 1,
        colorRendering: TerminalColorRenderingMode = .accurate,
        colorGamut: TerminalColorGamut = .auto,
        cursorStyle: CursorStyle = .block,
        selectionBackground: RGBColor? = nil,
        selectionForeground: RGBColor? = nil,
        searchBackground: RGBColor? = nil,
        searchForeground: RGBColor? = nil,
        promptGutterEnabled: Bool = true
    ) {
        self.resolver = resolver
        self.cursorColor = cursorColor
        self.cursorTextColor = cursorTextColor ?? resolver.defaultBackground
        self.canvasOpacity = max(0, min(1, canvasOpacity))
        self.colorConverter = RenderColorConverter(renderingMode: colorRendering, gamut: colorGamut)
        self.cursorStyle = cursorStyle
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.searchBackground = searchBackground
        self.searchForeground = searchForeground
        self.promptGutterEnabled = promptGutterEnabled
    }

    /// Convenience builder from a theme: resolver + cursor color in one call.
    public init(
        theme: HarnessThemeDefinition,
        boldBrightens: Bool = true,
        canvasOpacity: Float = 1,
        colorRendering: TerminalColorRenderingMode = .accurate,
        colorGamut: TerminalColorGamut = .auto,
        cursorStyle: CursorStyle = .block,
        selectionBackground: RGBColor? = nil,
        selectionForeground: RGBColor? = nil,
        searchBackground: RGBColor? = nil,
        searchForeground: RGBColor? = nil,
        promptGutterEnabled: Bool = true
    ) {
        let resolver = CellColorResolver(theme: theme, boldBrightens: boldBrightens)
        self.init(
            resolver: resolver,
            cursorColor: theme.cursor ?? theme.foreground,
            cursorTextColor: theme.cursorText ?? theme.background,
            canvasOpacity: canvasOpacity,
            colorRendering: colorRendering,
            colorGamut: colorGamut,
            cursorStyle: cursorStyle,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            searchBackground: searchBackground,
            searchForeground: searchForeground,
            promptGutterEnabled: promptGutterEnabled
        )
    }

    public func renderColor(_ color: RGBColor) -> RenderColor {
        colorConverter.color(color)
    }

    public func renderColor(_ color: RGBColor, alpha: Float) -> RenderColor {
        colorConverter.color(color, alpha: alpha)
    }

    /// Build a frame with an optional linear selection. The original entry point — kept so
    /// existing callers (mouse selection, search-free render) are byte-identical.
    public func build(_ snapshot: TerminalGridSnapshot, selection: TerminalSelection? = nil,
                      imageProvider: ((Int) -> DecodedImage?)? = nil) -> TerminalFrame {
        build(snapshot, region: selection.map(SelectionRegion.linear), searchHighlights: [],
              copyModeCursor: nil, imageProvider: imageProvider)
    }

    /// Build a frame with a selection region (linear or block), copy-mode search highlights,
    /// and an optional copy-mode cursor that renders even when the program cursor is hidden
    /// (e.g. scrolled into history). Shading precedence per cell: primary selection > search
    /// hit > normal.
    ///
    /// Pass `reusing:` (the previous frame) and `damage:` (from `TerminalEmulator.consumeDamage()`)
    /// to rebuild incrementally: rows the engine didn't mark dirty are copied from the previous
    /// frame instead of re-resolved. Reuse is taken only on the plain path (no selection/search/
    /// copy-mode, matching dimensions, not full damage); otherwise the whole frame is rebuilt. The
    /// reused rows are byte-identical to a full rebuild, so the result is visually identical either
    /// way — the caller must just ensure `previous` was built with the same builder/selection state.
    public func build(
        _ snapshot: TerminalGridSnapshot,
        region: SelectionRegion?,
        searchHighlights: [TerminalSelection] = [],
        copyModeCursor: (row: Int, column: Int)? = nil,
        imageProvider: ((Int) -> DecodedImage?)? = nil,
        reusing previous: TerminalFrame? = nil,
        damage: TerminalDamage? = nil
    ) -> TerminalFrame {
        let cols = snapshot.cols
        var cells = [RenderCell]()
        cells.reserveCapacity(cols * snapshot.rows)
        // Incremental rebuild: reuse the previous frame's `RenderCell`s for rows the engine
        // didn't mark dirty, recomputing only the dirty ones. Gated to the plain path — a
        // selection/search bakes per-cell highlight colors that the damage set doesn't track, so
        // any of those forces a full rebuild. The cursor overlay is applied by the renderer (not
        // baked into cells), so cursor movement never blocks reuse: clean rows stay byte-identical.
        let canReuse = region == nil && searchHighlights.isEmpty && copyModeCursor == nil
            && !(damage?.full ?? true)
            && previous?.columns == cols && previous?.rows == snapshot.rows
            && previous?.cells.count == cols * snapshot.rows
        if canReuse, let previous, let damage {
            for row in 0 ..< snapshot.rows {
                if damage.rows.contains(row) {
                    appendRow(row, snapshot: snapshot, region: region, searchHighlights: searchHighlights, into: &cells)
                } else {
                    cells.append(contentsOf: previous.cells[(row * cols) ..< ((row + 1) * cols)])
                }
            }
        } else {
            for row in 0 ..< snapshot.rows {
                appendRow(row, snapshot: snapshot, region: region, searchHighlights: searchHighlights, into: &cells)
            }
        }
        // The copy-mode cursor overrides the program cursor's position and forces it visible
        // (history snapshots hide the program cursor); otherwise the program cursor stands.
        let cursor: CursorRender
        if let cm = copyModeCursor {
            cursor = CursorRender(
                row: cm.row, column: cm.column, visible: true,
                color: renderColor(cursorColor), textColor: renderColor(cursorTextColor),
                style: cursorStyle
            )
        } else {
            cursor = CursorRender(
                row: snapshot.cursor.row, column: snapshot.cursor.col, visible: snapshot.cursor.visible,
                color: renderColor(cursorColor), textColor: renderColor(cursorTextColor),
                style: renderCursorStyle(userStyle: cursorStyle, programShape: snapshot.cursor.shape)
            )
        }
        // Resolve placements to drawable images (those whose pixels the provider can supply).
        var images: [FrameImage] = []
        if let imageProvider {
            for p in snapshot.images {
                guard let decoded = imageProvider(p.id) else { continue }
                images.append(FrameImage(id: p.id, column: p.col, row: p.row,
                                         columns: p.cols, rows: p.rows, z: p.z, image: decoded))
            }
        }
        // OSC 133 prompt gutter: resolve each marked row's stripe color from the palette —
        // ANSI green (success) / red (failure) / bright-black (prompt with no exit yet). Skipped
        // entirely when the user hasn't opted in (the default), so no stripe is drawn.
        let promptGutter = promptGutterEnabled ? resolvePromptGutter(snapshot.marks) : [:]
        return TerminalFrame(columns: snapshot.cols, rows: snapshot.rows, cells: cells,
                             cursor: cursor, images: images, promptGutter: promptGutter)
    }

    /// Build the `RenderCell`s for one viewport row (appending in column order). A row's cells
    /// depend only on its snapshot cells plus selection/search shading — the cursor overlay is
    /// applied later by the renderer — so this is the unit of incremental reuse in `build`.
    private func appendRow(_ row: Int, snapshot: TerminalGridSnapshot,
                           region: SelectionRegion?, searchHighlights: [TerminalSelection],
                           into cells: inout [RenderCell]) {
        for column in 0 ..< snapshot.cols {
            let cell = snapshot.cell(row: row, col: column) ?? .blank
            let colors = resolver.resolve(cell)
            // Underline color defaults to the resolved foreground when unset.
            let underline = resolver.resolved(cell.underlineColor, default: colors.foreground)
            // A cell shows the canvas only when its background is the terminal default
            // (no explicit SGR bg) and it isn't inverted (which promotes the foreground
            // into the bg slot). Those — and only those — get the translucent alpha.
            let isCanvasBackground = cell.background == .none && !cell.inverse
            // Precedence: primary selection (opaque) > search hit > normal.
            let selected = region?.contains(row: row, column: column) ?? false
            let isSearchHit = !selected && !searchHighlights.isEmpty
                && searchHighlights.contains { $0.contains(row: row, column: column) }
            let foreground: RenderColor
            let background: RenderColor
            // Skip the cell's background fill only when it resolves to the default canvas
            // color — the renderer already clears the target to that color. Highlights and
            // any non-default background must be drawn.
            let drawBackground: Bool
            if selected, let selBg = selectionBackground {
                background = renderColor(selBg)
                foreground = selectionForeground.map { renderColor($0) } ?? renderColor(colors.foreground)
                drawBackground = true
            } else if isSearchHit, let searchBg = searchBackground {
                background = renderColor(searchBg)
                foreground = searchForeground.map { renderColor($0) } ?? renderColor(colors.foreground)
                drawBackground = true
            } else {
                background = isCanvasBackground
                    ? renderColor(colors.background, alpha: canvasOpacity)
                    : renderColor(colors.background)
                foreground = renderColor(colors.foreground)
                // Default canvas cells match the clear color; everything else (explicit SGR
                // background, inverse) needs its quad.
                drawBackground = !isCanvasBackground
            }
            cells.append(RenderCell(
                row: row,
                column: column,
                codepoint: cell.codepoint,
                foreground: foreground,
                background: background,
                underlineColor: renderColor(underline),
                bold: cell.bold,
                italic: cell.italic,
                underline: cell.underline,
                strikethrough: cell.strikethrough,
                overline: cell.overline,
                width: cell.width,
                drawBackground: drawBackground
            ))
        }
    }

    /// Map OSC 133 semantic marks (viewport row → mark) to gutter stripe colors. A mark with a
    /// known exit is green (0) or red (non-zero); an unfinished prompt is neutral (bright-black).
    private func resolvePromptGutter(_ marks: [Int: SemanticMark]) -> [Int: RenderColor] {
        guard !marks.isEmpty else { return [:] }
        let success = renderColor(resolver.palette.color(at: 2))   // ANSI green
        let failure = renderColor(resolver.palette.color(at: 1))   // ANSI red
        let neutral = renderColor(resolver.palette.color(at: 8))   // bright black (gray)
        var gutter: [Int: RenderColor] = [:]
        gutter.reserveCapacity(marks.count)
        for (row, mark) in marks {
            if let exit = mark.exit { gutter[row] = (exit == 0) ? success : failure }
            else { gutter[row] = neutral }
        }
        return gutter
    }
}
