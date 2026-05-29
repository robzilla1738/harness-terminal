import AppKit
import HarnessTerminalKit

@MainActor
struct HarnessChromePalette {
    let isDark: Bool
    let terminalBackground: NSColor
    let sidebarBackground: NSColor
    let surfaceElevated: NSColor
    let border: NSColor
    let borderStrong: NSColor
    let accent: NSColor
    let accentSoft: NSColor
    /// Stroke color for keyboard-focus rings and the active-pane border. Consumers
    /// apply their own alpha; this carries the hue.
    let focusRing: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textTertiary: NSColor
    let rowSelectedFill: NSColor
    let rowHoverFill: NSColor
    let iconHoverFill: NSColor
    let waiting: NSColor
    let danger: NSColor
    let success: NSColor
    let idleStatus: NSColor

    static let fallback = HarnessChromePalette.from(
        backgroundHex: ThemeManager.defaultBaselineBackgroundHex,
        foregroundHex: ThemeManager.defaultBaselineForegroundHex,
        cursorHex: ThemeManager.defaultBaselineForegroundHex
    )

    /// Build a palette directly from explicit hex strings (used when the user has
    /// set `background`/`foreground` in their terminal config — we want to honor
    /// the exact black-and-white look rather than a named theme's tinted palette).
    static func from(backgroundHex: String, foregroundHex: String, cursorHex: String? = nil) -> HarnessChromePalette {
        let background = color(from: backgroundHex)
        let foreground = color(from: foregroundHex)
        let accent = cursorHex.map { color(from: $0) } ?? blend(foreground, toward: NSColor(srgbRed: 0.55, green: 0.7, blue: 1.0, alpha: 1), fraction: 0.3)
        // A pleasant default ANSI-ish set derived from the bg/fg luminance.
        let waiting = NSColor(srgbRed: 0.51, green: 0.69, blue: 0.96, alpha: 1)
        let danger = NSColor(srgbRed: 0.93, green: 0.49, blue: 0.55, alpha: 1)
        let success = NSColor(srgbRed: 0.59, green: 0.83, blue: 0.55, alpha: 1)
        let idle = blend(foreground, toward: background, fraction: 0.55)
        return build(
            background: background,
            foreground: foreground,
            accent: accent,
            waiting: waiting,
            danger: danger,
            success: success,
            idle: idle
        )
    }

    private static func build(
        background: NSColor,
        foreground: NSColor,
        accent: NSColor,
        waiting: NSColor,
        danger: NSColor,
        success: NSColor,
        idle: NSColor
    ) -> HarnessChromePalette {
        let isDark = perceivedBrightness(of: background) < 0.5
        // Lift the chrome (sidebar, tab strip, status line, overlays) a few percent
        // off the terminal background so the terminal pane reads as its own bounded,
        // true-color surface rather than one flat sheet — the terminal then shows
        // ghostty's rich colors without the surrounding chrome washing into it.
        // This stays a *pure function* of the resolved canvas (terminalBackground is
        // unchanged below), so the single-source-of-truth contract holds.
        let sidebar = blend(background, toward: foreground, fraction: isDark ? 0.05 : 0.045)
        // Light themes need firmer separation/fills — at the dark-mode alphas the
        // borders and hover states are effectively invisible on a bright surface.
        let elevated = foreground.withAlphaComponent(isDark ? 0.07 : 0.08)

        return HarnessChromePalette(
            isDark: isDark,
            terminalBackground: background,
            sidebarBackground: sidebar,
            surfaceElevated: elevated,
            border: foreground.withAlphaComponent(isDark ? 0.07 : 0.14),
            borderStrong: foreground.withAlphaComponent(isDark ? 0.12 : 0.20),
            accent: accent,
            accentSoft: accent.withAlphaComponent(0.16),
            focusRing: accent,
            textPrimary: foreground,
            textSecondary: foreground.withAlphaComponent(0.66),
            textTertiary: foreground.withAlphaComponent(0.40),
            rowSelectedFill: foreground.withAlphaComponent(isDark ? 0.08 : 0.10),
            rowHoverFill: foreground.withAlphaComponent(isDark ? 0.045 : 0.065),
            iconHoverFill: foreground.withAlphaComponent(isDark ? 0.08 : 0.10),
            waiting: waiting,
            danger: danger,
            success: success,
            idleStatus: idle
        )
    }

    private static func color(from hex: String) -> NSColor {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else {
            return .white
        }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func blend(_ base: NSColor, toward: NSColor, fraction: CGFloat) -> NSColor {
        guard let baseRGB = base.usingColorSpace(.sRGB),
              let towardRGB = toward.usingColorSpace(.sRGB)
        else { return base }
        let f = min(max(fraction, 0), 1)
        return NSColor(
            srgbRed: baseRGB.redComponent * (1 - f) + towardRGB.redComponent * f,
            green: baseRGB.greenComponent * (1 - f) + towardRGB.greenComponent * f,
            blue: baseRGB.blueComponent * (1 - f) + towardRGB.blueComponent * f,
            alpha: 1
        )
    }

    private static func perceivedBrightness(of color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        return rgb.redComponent * 0.299 + rgb.greenComponent * 0.587 + rgb.blueComponent * 0.114
    }
}

@MainActor
enum HarnessChrome {
    private(set) static var current: HarnessChromePalette = .fallback
    /// Window background opacity (0…1). When < 1, chrome backgrounds gain alpha so
    /// the underlying NSVisualEffectView blur can show through.
    static var backgroundOpacity: CGFloat = 1
    /// Terminal backdrop blur (0…100) from settings; the renderer applies this on each
    /// terminal surface. Chrome uses this for optional vibrancy tuning only.
    static var backgroundBlur: Int = 0

    static func update(themeName: String) {
        update(themeName: themeName, opacity: backgroundOpacity, blur: backgroundBlur)
    }

    /// Resolve the palette honoring the user's `customBackgroundHex/customForegroundHex`
    /// overrides — when a terminal config explicitly sets `background = #000000`, we
    /// must paint pure black chrome rather than the named theme's tinted bg. Either
    /// override may be present alone; missing slots fall back to the theme so the
    /// chrome (sidebar/tabs/status line) tracks the same color as the terminal canvas.
    static func update(
        themeName: String,
        opacity: CGFloat,
        blur: Int = 0,
        backgroundHex: String? = nil,
        foregroundHex: String? = nil,
        cursorHex: String? = nil
    ) {
        // Resolve through the same single source of truth the terminal surface
        // uses, so chrome and terminal paint the identical canvas color.
        let canvas = ThemeManager.resolvedCanvas(
            themeName: themeName,
            customBackgroundHex: backgroundHex,
            customForegroundHex: foregroundHex,
            customCursorHex: cursorHex
        )
        current = HarnessChromePalette.from(
            backgroundHex: canvas.backgroundHex,
            foregroundHex: canvas.foregroundHex,
            cursorHex: canvas.cursorHex
        )
        backgroundOpacity = max(0, min(1, opacity))
        backgroundBlur = max(0, min(100, blur))
    }
}
