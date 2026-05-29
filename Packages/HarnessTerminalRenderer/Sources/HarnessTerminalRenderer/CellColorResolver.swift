import HarnessTerminalEngine
import HarnessTheme

/// The concrete foreground/background a cell should be drawn with, after the palette,
/// default colors, and attribute effects (bold-bright, faint, inverse, conceal) are
/// applied. This is what the Metal renderer rasterizes.
public struct ResolvedCellColors: Equatable, Sendable {
    public var foreground: RGBColor
    public var background: RGBColor

    public init(foreground: RGBColor, background: RGBColor) {
        self.foreground = foreground
        self.background = background
    }
}

/// Turns a `TerminalGridCell`'s logical colors + attributes into final RGB, exactly the
/// way mainstream terminals do. Keeping this as pure, testable logic (separate from any
/// GPU code) is how we guarantee the "crisp, correct color" without needing a screen to
/// verify the rules.
///
/// Resolution order (matches xterm):
/// 1. base fg/bg from palette / truecolor / defaults,
/// 2. bold brightens a low (0–7) palette foreground to its bright (8–15) variant,
/// 3. faint dims the foreground toward the background,
/// 4. inverse swaps fg and bg,
/// 5. conceal (invisible) sets fg = bg.
public struct CellColorResolver: Sendable {
    public let palette: ANSIPalette
    public let defaultForeground: RGBColor
    public let defaultBackground: RGBColor
    /// When true, a bold cell whose foreground is ANSI 0–7 is drawn with 8–15 (the
    /// classic "bold = bright" behavior). Truecolor and 256-cube colors are unaffected.
    public let boldBrightens: Bool
    /// Fraction the foreground is mixed toward the background for faint/dim text.
    public let faintFraction: Double

    public init(
        palette: ANSIPalette,
        defaultForeground: RGBColor,
        defaultBackground: RGBColor,
        boldBrightens: Bool = true,
        faintFraction: Double = 0.5
    ) {
        self.palette = palette
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.boldBrightens = boldBrightens
        self.faintFraction = faintFraction
    }

    /// Convenience: build a resolver straight from a theme.
    public init(theme: HarnessThemeDefinition, boldBrightens: Bool = true) {
        self.init(
            palette: ANSIPalette(base16: theme.palette),
            defaultForeground: theme.foreground,
            defaultBackground: theme.background,
            boldBrightens: boldBrightens
        )
    }

    public func resolve(_ cell: TerminalGridCell) -> ResolvedCellColors {
        // 1 + 2: base foreground, with bold-bright applied to low palette indices.
        var fg: RGBColor
        if boldBrightens, cell.bold, case let .palette(i) = cell.foreground, i < 8 {
            fg = palette.color(at: i + 8)
        } else {
            fg = rgb(cell.foreground, default: defaultForeground)
        }
        var bg = rgb(cell.background, default: defaultBackground)

        // 3: faint dims the foreground toward the background.
        if cell.faint {
            fg = fg.blended(toward: bg, fraction: faintFraction)
        }

        // 4: inverse swaps.
        if cell.inverse {
            swap(&fg, &bg)
        }

        // 5: conceal makes the glyph invisible by matching fg to bg.
        if cell.invisible {
            fg = bg
        }

        return ResolvedCellColors(foreground: fg, background: bg)
    }

    /// Resolve a single logical color to RGB (palette / truecolor / default). Public so
    /// the frame builder can resolve e.g. underline colors independently of fg/bg.
    public func resolved(_ color: TerminalGridColor, default fallback: RGBColor) -> RGBColor {
        switch color {
        case .none:
            return fallback
        case let .palette(i):
            return palette.color(at: i)
        case let .rgb(r, g, b):
            return RGBColor(red: r, green: g, blue: b)
        }
    }

    private func rgb(_ color: TerminalGridColor, default fallback: RGBColor) -> RGBColor {
        resolved(color, default: fallback)
    }
}
