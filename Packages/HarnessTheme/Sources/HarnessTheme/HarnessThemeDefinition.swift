import Foundation

/// A named color theme: the canvas colors (background/foreground/cursor), selection
/// and bold accents, and the 16-entry ANSI palette. This is the native replacement for
/// the the previous theme model.
///
/// It exposes both typed `RGBColor` values and `…Hex` string accessors so the existing
/// `ThemeManager` (which speaks `#rrggbb`) can switch over with minimal change.
public struct HarnessThemeDefinition: Equatable, Sendable, Codable {
    public let name: String
    public let background: RGBColor
    public let foreground: RGBColor
    public let cursor: RGBColor?
    public let cursorText: RGBColor?
    public let selectionBackground: RGBColor?
    public let selectionForeground: RGBColor?
    public let bold: RGBColor?
    /// Exactly 16 ANSI colors (0–7 normal, 8–15 bright). Built-in themes always provide
    /// all 16; imported themes are validated to 16 on load.
    public let palette: [RGBColor]

    public init(
        name: String,
        background: RGBColor,
        foreground: RGBColor,
        cursor: RGBColor? = nil,
        cursorText: RGBColor? = nil,
        selectionBackground: RGBColor? = nil,
        selectionForeground: RGBColor? = nil,
        bold: RGBColor? = nil,
        palette: [RGBColor]
    ) {
        self.name = name
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.bold = bold
        self.palette = palette
    }

    public var isDark: Bool { background.isDark }

    // MARK: - Hex accessors (parity with the previous the theme model API)

    public var backgroundHex: String { background.hexString }
    public var foregroundHex: String { foreground.hexString }
    public var cursorHex: String? { cursor?.hexString }
    public var cursorTextHex: String? { cursorText?.hexString }
    public var selectionBackgroundHex: String? { selectionBackground?.hexString }
    public var selectionForegroundHex: String? { selectionForeground?.hexString }
    public var boldHex: String? { bold?.hexString }

    /// 16 ANSI palette entries as `#rrggbb` (nil-padded if a theme somehow has fewer,
    /// which built-ins never do).
    public var paletteHex: [String?] {
        (0 ..< 16).map { idx in idx < palette.count ? palette[idx].hexString : nil }
    }
}

/// A convenience builder used by the hand-written built-in catalog so each theme reads
/// as a compact list of hex strings. Force-unwraps are audited: the literals below are
/// all valid 6-digit hexes, exercised by `HarnessThemeCatalogTests`.
extension HarnessThemeDefinition {
    static func make(
        _ name: String,
        bg: String,
        fg: String,
        cursor: String? = nil,
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [String]
    ) -> HarnessThemeDefinition {
        HarnessThemeDefinition(
            name: name,
            background: RGBColor(hex: bg)!,
            foreground: RGBColor(hex: fg)!,
            cursor: cursor.flatMap { RGBColor(hex: $0) },
            cursorText: nil,
            selectionBackground: selectionBackground.flatMap { RGBColor(hex: $0) },
            selectionForeground: selectionForeground.flatMap { RGBColor(hex: $0) },
            bold: nil,
            palette: palette.map { RGBColor(hex: $0)! }
        )
    }
}
