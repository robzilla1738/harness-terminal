import Foundation
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
/// 3.5 minimum-contrast lifts the foreground away from the background until the ratio is met,
/// 4. inverse swaps fg and bg (the ratio is symmetric, so it still holds after the swap),
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
    /// Minimum WCAG contrast ratio (1…21) forced between a cell's foreground and background.
    /// 1 = off (no adjustment, byte-identical output); higher lifts dim text to legibility.
    public let minimumContrast: Double
    /// DECSCNM (DECSET 5) screen reverse video: the screen's *default* foreground and
    /// background swap, exactly like xterm — cells with explicit SGR colors keep them.
    /// `false` (the default) is byte-identical to the pre-DECSCNM resolver.
    public var reverseVideo: Bool = false

    /// The defaults after the DECSCNM swap — every default-color resolution funnels through
    /// these so the swap can never half-apply.
    var effectiveDefaultForeground: RGBColor { reverseVideo ? defaultBackground : defaultForeground }
    var effectiveDefaultBackground: RGBColor { reverseVideo ? defaultForeground : defaultBackground }

    public init(
        palette: ANSIPalette,
        defaultForeground: RGBColor,
        defaultBackground: RGBColor,
        boldBrightens: Bool = true,
        faintFraction: Double = 0.5,
        minimumContrast: Double = 1
    ) {
        self.palette = palette
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.boldBrightens = boldBrightens
        self.faintFraction = faintFraction
        self.minimumContrast = minimumContrast
    }

    /// Convenience: build a resolver straight from a theme.
    public init(theme: HarnessThemeDefinition, boldBrightens: Bool = true, minimumContrast: Double = 1) {
        self.init(
            palette: ANSIPalette(base16: theme.palette),
            defaultForeground: theme.foreground,
            defaultBackground: theme.background,
            boldBrightens: boldBrightens,
            minimumContrast: minimumContrast
        )
    }

    public func resolve(_ cell: TerminalGridCell) -> ResolvedCellColors {
        // 1 + 2: base foreground, with bold-bright applied to low palette indices.
        var fg: RGBColor
        if boldBrightens, cell.bold, case let .palette(i) = cell.foreground, i < 8 {
            fg = palette.color(at: Int(i) + 8)
        } else {
            fg = rgb(cell.foreground, default: effectiveDefaultForeground)
        }
        var bg = rgb(cell.background, default: effectiveDefaultBackground)

        // 3: faint dims the foreground toward the background.
        if cell.faint {
            fg = fg.blended(toward: bg, fraction: faintFraction)
        }

        // 3.5: enforce a minimum contrast (skip concealed cells, which want fg == bg). Applied
        // before inverse — the ratio is symmetric, so it still holds after the swap.
        if minimumContrast > 1, !cell.invisible {
            fg = Self.ensureContrast(foreground: fg, background: bg, ratio: minimumContrast)
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

    /// WCAG relative luminance of an sRGB color (0…1).
    static func relativeLuminance(_ c: RGBColor) -> Double {
        func channel(_ v: UInt8) -> Double {
            let s = Double(v) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }

    /// WCAG contrast ratio between two colors (1…21). Symmetric.
    static func contrastRatio(_ a: RGBColor, _ b: RGBColor) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Lift `foreground` toward black or white (whichever raises contrast vs `background`) by the
    /// minimal amount needed to meet `ratio`. Returns the original when it already passes, or the
    /// extreme as a best effort when even that can't reach the ratio (a mid-tone background).
    static func ensureContrast(foreground fg: RGBColor, background bg: RGBColor, ratio: Double) -> RGBColor {
        guard contrastRatio(fg, bg) < ratio else { return fg }
        let target: RGBColor = relativeLuminance(bg) < 0.5
            ? RGBColor(red: 255, green: 255, blue: 255)
            : RGBColor(red: 0, green: 0, blue: 0)
        guard contrastRatio(target, bg) >= ratio else { return target }
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 12 { // binary search the minimal blend toward the target
            let mid = (lo + hi) / 2
            if contrastRatio(fg.blended(toward: target, fraction: mid), bg) >= ratio { hi = mid }
            else { lo = mid }
        }
        return fg.blended(toward: target, fraction: hi)
    }

    /// Resolve a single logical color to RGB (palette / truecolor / default). Public so
    /// the frame builder can resolve e.g. underline colors independently of fg/bg.
    public func resolved(_ color: TerminalGridColor, default fallback: RGBColor) -> RGBColor {
        switch color {
        case .none:
            return fallback
        case let .palette(i):
            return palette.color(at: Int(i))
        case let .rgb(r, g, b):
            return RGBColor(red: r, green: g, blue: b)
        }
    }

    private func rgb(_ color: TerminalGridColor, default fallback: RGBColor) -> RGBColor {
        resolved(color, default: fallback)
    }
}
