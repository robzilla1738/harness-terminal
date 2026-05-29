import HarnessTerminalEngine
import HarnessTheme

/// A color as normalized floats (0...1) — the form a Metal shader consumes. Built from
/// an `RGBColor`; the colorspace interpretation (sRGB vs Display-P3) is decided by the
/// layer the renderer draws into, not here.
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

    public init(_ c: RGBColor) {
        self.init(
            red: Float(c.red) / 255,
            green: Float(c.green) / 255,
            blue: Float(c.blue) / 255,
            alpha: Float(c.alpha) / 255
        )
    }

    /// RGB from the color, but with an explicit alpha (0...1) — used to make the
    /// translucent canvas background while keeping the color channels exact.
    public init(_ c: RGBColor, alpha: Float) {
        self.init(
            red: Float(c.red) / 255,
            green: Float(c.green) / 255,
            blue: Float(c.blue) / 255,
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

    /// True when there is a visible glyph to rasterize (not blank/space and not the
    /// trailing spacer of a wide cell). Background is still drawn for every cell.
    public var hasGlyph: Bool {
        guard width != .spacerTail else { return false }
        return codepoint != 0 && codepoint != 0x20
    }
}

/// A render-ready frame: the resolved background-pass + glyph-pass data for one grid
/// snapshot, plus the cursor. Pure value type — the Metal renderer turns this into draw
/// calls, and it is fully unit-testable without a GPU.
public struct TerminalFrame: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    /// Row-major, `columns * rows` long (every grid position, so the background pass can
    /// fill the whole surface).
    public var cells: [RenderCell]
    public var cursor: CursorRender

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

    public init(
        row: Int,
        column: Int,
        visible: Bool,
        color: RenderColor,
        textColor: RenderColor,
        style: CursorStyle = .block
    ) {
        self.row = row
        self.column = column
        self.visible = visible
        self.color = color
        self.textColor = textColor
        self.style = style
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

    public init(
        resolver: CellColorResolver,
        cursorColor: RGBColor,
        cursorTextColor: RGBColor? = nil,
        canvasOpacity: Float = 1,
        cursorStyle: CursorStyle = .block,
        selectionBackground: RGBColor? = nil,
        selectionForeground: RGBColor? = nil
    ) {
        self.resolver = resolver
        self.cursorColor = cursorColor
        self.cursorTextColor = cursorTextColor ?? resolver.defaultBackground
        self.canvasOpacity = max(0, min(1, canvasOpacity))
        self.cursorStyle = cursorStyle
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
    }

    /// Convenience builder from a theme: resolver + cursor color in one call.
    public init(
        theme: HarnessThemeDefinition,
        boldBrightens: Bool = true,
        canvasOpacity: Float = 1,
        cursorStyle: CursorStyle = .block,
        selectionBackground: RGBColor? = nil,
        selectionForeground: RGBColor? = nil
    ) {
        let resolver = CellColorResolver(theme: theme, boldBrightens: boldBrightens)
        self.init(
            resolver: resolver,
            cursorColor: theme.cursor ?? theme.foreground,
            cursorTextColor: theme.cursorText ?? theme.background,
            canvasOpacity: canvasOpacity,
            cursorStyle: cursorStyle,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground
        )
    }

    public func build(_ snapshot: TerminalGridSnapshot, selection: TerminalSelection? = nil) -> TerminalFrame {
        var cells = [RenderCell]()
        cells.reserveCapacity(snapshot.cols * snapshot.rows)
        for row in 0 ..< snapshot.rows {
            for column in 0 ..< snapshot.cols {
                let cell = snapshot.cell(row: row, col: column) ?? .blank
                let colors = resolver.resolve(cell)
                // Underline color defaults to the resolved foreground when unset.
                let underline = resolver.resolved(cell.underlineColor, default: colors.foreground)
                // A cell shows the canvas only when its background is the terminal default
                // (no explicit SGR bg) and it isn't inverted (which promotes the foreground
                // into the bg slot). Those — and only those — get the translucent alpha.
                let isCanvasBackground = cell.background == .none && !cell.inverse
                // Selected cells take the (opaque) selection colors over everything else.
                let selected = selection?.contains(row: row, column: column) ?? false
                let foreground: RenderColor
                let background: RenderColor
                if selected, let selBg = selectionBackground {
                    background = RenderColor(selBg)
                    foreground = selectionForeground.map { RenderColor($0) } ?? RenderColor(colors.foreground)
                } else {
                    background = isCanvasBackground
                        ? RenderColor(colors.background, alpha: canvasOpacity)
                        : RenderColor(colors.background)
                    foreground = RenderColor(colors.foreground)
                }
                cells.append(RenderCell(
                    row: row,
                    column: column,
                    codepoint: cell.codepoint,
                    foreground: foreground,
                    background: background,
                    underlineColor: RenderColor(underline),
                    bold: cell.bold,
                    italic: cell.italic,
                    underline: cell.underline,
                    strikethrough: cell.strikethrough,
                    overline: cell.overline,
                    width: cell.width
                ))
            }
        }
        return TerminalFrame(
            columns: snapshot.cols,
            rows: snapshot.rows,
            cells: cells,
            cursor: CursorRender(
                row: snapshot.cursor.row,
                column: snapshot.cursor.col,
                visible: snapshot.cursor.visible,
                color: RenderColor(cursorColor),
                textColor: RenderColor(cursorTextColor),
                style: cursorStyle
            )
        )
    }
}
