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

/// Where to draw the cursor and in what color (already resolved). `visible` follows the
/// terminal's DECTCEM state.
public struct CursorRender: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var visible: Bool
    public var color: RenderColor
}

/// Turns an engine `TerminalGridSnapshot` into a `TerminalFrame` by resolving every
/// cell's colors through a `CellColorResolver`. This is the single bridge between the
/// headless engine and the GPU renderer — keeping it pure means the renderer never has
/// to know about palettes, defaults, or attribute rules.
public struct FrameBuilder {
    public let resolver: CellColorResolver
    /// Cursor block color (typically the theme cursor color).
    public let cursorColor: RGBColor

    public init(resolver: CellColorResolver, cursorColor: RGBColor) {
        self.resolver = resolver
        self.cursorColor = cursorColor
    }

    /// Convenience builder from a theme: resolver + cursor color in one call.
    public init(theme: HarnessThemeDefinition, boldBrightens: Bool = true) {
        let resolver = CellColorResolver(theme: theme, boldBrightens: boldBrightens)
        self.init(resolver: resolver, cursorColor: theme.cursor ?? theme.foreground)
    }

    public func build(_ snapshot: TerminalGridSnapshot) -> TerminalFrame {
        var cells = [RenderCell]()
        cells.reserveCapacity(snapshot.cols * snapshot.rows)
        for row in 0 ..< snapshot.rows {
            for column in 0 ..< snapshot.cols {
                let cell = snapshot.cell(row: row, col: column) ?? .blank
                let colors = resolver.resolve(cell)
                // Underline color defaults to the resolved foreground when unset.
                let underline = resolver.resolved(cell.underlineColor, default: colors.foreground)
                cells.append(RenderCell(
                    row: row,
                    column: column,
                    codepoint: cell.codepoint,
                    foreground: RenderColor(colors.foreground),
                    background: RenderColor(colors.background),
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
                color: RenderColor(cursorColor)
            )
        )
    }
}
