import Foundation

/// A renderer-agnostic color for `#[fg=…,bg=…]` style spans. HarnessCore stays engine-free,
/// so this mirrors the engine's color shape; the GUI maps it to `NSColor` and the compositor
/// to an SGR palette/truecolor code. `none` = the surface default.
public enum FormatColor: Equatable, Sendable {
    case none
    case palette(Int)
    case rgb(r: UInt8, g: UInt8, b: UInt8)
}

/// One run of status text plus the style established by the `#[…]` directives in effect. The
/// single intermediate both status renderers consume: the GUI builds an `NSAttributedString`
/// from these, the compositor emits one SGR run per segment — so styling lives in one place.
public struct StyledSegment: Equatable, Sendable {
    public var text: String
    public var fg: FormatColor?
    public var bg: FormatColor?
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var reverse: Bool
    public var dim: Bool

    public init(
        text: String,
        fg: FormatColor? = nil,
        bg: FormatColor? = nil,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        reverse: Bool = false,
        dim: Bool = false
    ) {
        self.text = text
        self.fg = fg
        self.bg = bg
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.reverse = reverse
        self.dim = dim
    }
}
