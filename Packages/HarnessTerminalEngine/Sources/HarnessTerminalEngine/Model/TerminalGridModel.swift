import Foundation

/// A cell color. `none` means "use the surface default" (default fg/bg as resolved
/// by the renderer/theme); `palette` is an ANSI 0–255 index; `rgb` is direct truecolor.
///
/// These are the engine's public, renderer-agnostic color values — the same shape the
/// headless `readGrid` snapshot exposes and the live renderer consumes. They carry no
/// platform color type so the engine stays Foundation-only and unit-testable without a GPU.
public enum TerminalGridColor: Equatable, Sendable {
    case none
    case palette(Int)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

/// Underline style (ECMA-48 SGR 4 plus the `4:N` substyles modern terminals understand).
public enum TerminalGridUnderline: Equatable, Sendable {
    case none
    case single
    case double
    case curly
    case dotted
    case dashed
}

/// How many columns a cell occupies. `wide` is the leading cell of a double-width
/// glyph (e.g. CJK); `spacerTail` is the empty trailing column it reserves — renderers
/// and the compositor skip it because the wide glyph already spans both columns.
public enum TerminalCellWidth: Equatable, Sendable {
    case normal
    case wide
    case spacerTail
}

/// A single grid cell: one glyph plus its full SGR attribute set. `Equatable` so the
/// compositor's back-buffer diff and the renderer's damage tracking can compare cells.
public struct TerminalGridCell: Equatable, Sendable {
    /// Primary Unicode scalar of the cell's grapheme. `0` renders as blank.
    public var codepoint: UInt32
    public var foreground: TerminalGridColor
    public var background: TerminalGridColor
    public var underlineColor: TerminalGridColor
    public var bold: Bool
    public var faint: Bool
    public var italic: Bool
    public var underline: TerminalGridUnderline
    public var blink: Bool
    public var inverse: Bool
    public var invisible: Bool
    public var strikethrough: Bool
    public var overline: Bool
    public var width: TerminalCellWidth

    public init(
        codepoint: UInt32 = 0,
        foreground: TerminalGridColor = .none,
        background: TerminalGridColor = .none,
        underlineColor: TerminalGridColor = .none,
        bold: Bool = false,
        faint: Bool = false,
        italic: Bool = false,
        underline: TerminalGridUnderline = .none,
        blink: Bool = false,
        inverse: Bool = false,
        invisible: Bool = false,
        strikethrough: Bool = false,
        overline: Bool = false,
        width: TerminalCellWidth = .normal
    ) {
        self.codepoint = codepoint
        self.foreground = foreground
        self.background = background
        self.underlineColor = underlineColor
        self.bold = bold
        self.faint = faint
        self.italic = italic
        self.underline = underline
        self.blink = blink
        self.inverse = inverse
        self.invisible = invisible
        self.strikethrough = strikethrough
        self.overline = overline
        self.width = width
    }

    /// An empty default-styled cell (a space-equivalent with no attributes).
    public static let blank = TerminalGridCell()
}

/// Cursor state in a snapshot: 0-based grid position + visibility.
public struct TerminalCursor: Equatable, Sendable {
    public var row: Int
    public var col: Int
    public var visible: Bool

    public init(row: Int = 0, col: Int = 0, visible: Bool = true) {
        self.row = row
        self.col = col
        self.visible = visible
    }
}

/// An immutable snapshot of the active screen: a `cols × rows` flattened cell array
/// (row-major) plus the cursor. This is what `readGrid()` returns and what the
/// compositor / renderer consume. Pure value type, `Sendable`, safe to hand across
/// threads.
public struct TerminalGridSnapshot: Equatable, Sendable {
    public let cols: Int
    public let rows: Int
    /// Row-major: index `row * cols + col`. Always `cols * rows` long.
    public let cells: [TerminalGridCell]
    public let cursor: TerminalCursor

    public init(cols: Int, rows: Int, cells: [TerminalGridCell], cursor: TerminalCursor) {
        self.cols = cols
        self.rows = rows
        self.cells = cells
        self.cursor = cursor
    }

    /// The cell at (`row`, `col`), or `nil` if out of bounds. Bounds-checked so callers
    /// (compositor, tests) can index defensively.
    public func cell(row: Int, col: Int) -> TerminalGridCell? {
        guard row >= 0, row < rows, col >= 0, col < cols else { return nil }
        return cells[row * cols + col]
    }
}
