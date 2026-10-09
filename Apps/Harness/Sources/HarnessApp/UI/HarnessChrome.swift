import AppKit
import HarnessCore
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
    /// Solid active-pill fill. Label contrast against this fill is at least 3:1.
    let activePillFill: NSColor
    /// Label color painted on `activePillFill`.
    let activePillLabel: NSColor
    let rowHoverFill: NSColor
    let iconHoverFill: NSColor
    /// Fill of the plain-shell icon tile: a step darker than the surface on dark themes.
    let iconTileFill: NSColor
    let waiting: NSColor
    /// A program blocked on the person (permission, question): warm orange.
    let attention: NSColor
    let danger: NSColor
    let success: NSColor
    let idleStatus: NSColor

    /// Divider hairline on dark themes when the user hasn't set a custom `dividerHex`: a quiet
    /// near-background line. Shared by the renderer (`MainSplitViewController.resolvedDividerColor`)
    /// and the Settings divider swatch so they never drift.
    static let defaultDarkDividerHex = "#1E1E1E"

    static let fallback = HarnessChromePalette.from(
        backgroundHex: ThemeManager.defaultBaselineBackgroundHex,
        foregroundHex: ThemeManager.defaultBaselineForegroundHex,
        cursorHex: ThemeManager.defaultBaselineCursorHex
    )

    /// Build a palette directly from explicit hex strings (used when the user has
    /// set `background`/`foreground` in their terminal config — we want to honor
    /// the exact black-and-white look rather than a named theme's tinted palette).
    static func from(backgroundHex: String, foregroundHex: String, cursorHex: String? = nil) -> HarnessChromePalette {
        // One spec for every chrome surface. Tabs, sidebar, pane headers, and the
        // switcher read the resulting palette instead of a hardcoded dark fill.
        let spec = ChromePaletteSpec.resolve(backgroundHex: backgroundHex, foregroundHex: foregroundHex)
        let background = nsColor(spec.surface)
        let foreground = nsColor(spec.textPrimary)
        let accent = cursorHex.map { color(from: $0) } ?? blend(foreground, toward: NSColor(srgbRed: 0.55, green: 0.7, blue: 1.0, alpha: 1), fraction: 0.3)
        // A pleasant default ANSI-ish set derived from the bg/fg luminance.
        let waiting = NSColor(srgbRed: 0.51, green: 0.69, blue: 0.96, alpha: 1)
        let danger = NSColor(srgbRed: 0.93, green: 0.49, blue: 0.55, alpha: 1)
        let success = NSColor(srgbRed: 0.59, green: 0.83, blue: 0.55, alpha: 1)
        let idle = blend(foreground, toward: background, fraction: 0.55)
        return build(
            spec: spec,
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
        spec: ChromePaletteSpec,
        background: NSColor,
        foreground: NSColor,
        accent: NSColor,
        waiting: NSColor,
        danger: NSColor,
        success: NSColor,
        idle: NSColor
    ) -> HarnessChromePalette {
        let isDark = spec.isDark
        // Recess the frame around the terminal, preserving the terminal's exact
        // theme colors. The same window blur remains visible through both surfaces.
        let sidebar = blend(background, toward: .black, fraction: isDark ? 0.18 : 0.035)
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
            // Dark secondary stays a translucent lift — it settles into the dark canvas.
            // Light secondary and tertiary are opaque. Alpha ink on a bright, translucent
            // surface is what makes light-mode chrome type look fuzzy and washed out:
            // subpixel antialiasing fringes against clear instead of against the paper.
            textSecondary: secondaryInk(foreground: foreground, on: background, isDark: isDark),
            textTertiary: tertiaryInk(foreground: foreground, on: background, isDark: isDark),
            rowSelectedFill: nsColor(spec.activePillFill),
            activePillFill: nsColor(spec.activePillFill),
            activePillLabel: nsColor(spec.activePillLabel),
            rowHoverFill: foreground.withAlphaComponent(isDark ? 0.045 : 0.065),
            iconHoverFill: foreground.withAlphaComponent(isDark ? 0.08 : 0.10),
            iconTileFill: isDark
                ? blend(background, toward: .black, fraction: 0.35)
                : blend(background, toward: foreground, fraction: 0.85),
            waiting: waiting,
            attention: NSColor(srgbRed: 0.95, green: 0.62, blue: 0.33, alpha: 1),
            danger: danger,
            success: success,
            idleStatus: idle
        )
    }

    private static func nsColor(_ color: ChromeColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
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

    /// Opaque mix of `foreground` toward the surface. `fraction` is how far the ink
    /// moves toward the background (0 = full foreground).
    private static func secondaryInk(foreground: NSColor, on background: NSColor, isDark: Bool) -> NSColor {
        if isDark { return foreground.withAlphaComponent(0.66) }
        return blend(foreground, toward: background, fraction: 0.22)
    }

    private static func tertiaryInk(foreground: NSColor, on background: NSColor, isDark: Bool) -> NSColor {
        if isDark { return foreground.withAlphaComponent(0.40) }
        return blend(foreground, toward: background, fraction: 0.40)
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

}

@MainActor
enum HarnessChrome {
    private(set) static var current: HarnessChromePalette = .fallback
    /// Window background opacity (0…1). When < 1, chrome backgrounds gain alpha so
    /// the underlying NSVisualEffectView blur can show through.
    static var backgroundOpacity: CGFloat = 1
    /// Opacity the window actually paints. Light appearance may raise this above the stored
    /// setting so type stays readable; `backgroundOpacity` itself stays the stored value.
    static var paintOpacity: CGFloat = 1
    /// A denser tint sets the frame behind the terminal without stacking materials.
    /// Fully clear and fully opaque settings retain their endpoints.
    static var framePaintOpacity: CGFloat {
        let opacity = paintOpacity
        return current.isDark ? opacity + 0.45 * opacity * (1 - opacity) : opacity
    }
    /// Terminal backdrop blur (0…100) from settings; the renderer applies this on each
    /// terminal surface. Chrome uses this for optional vibrancy tuning only.
    static var backgroundBlur: Int = 0

    static func update(themeName: String) {
        update(themeName: themeName, opacity: backgroundOpacity, blur: backgroundBlur)
    }

    /// Resolve the palette honoring the user's `customBackgroundHex/customForegroundHex`
    /// overrides — when a terminal config explicitly sets `background = #000000`, we
    /// derive chrome from that black rather than the named theme's tinted bg. Either
    /// override may be present alone; missing slots fall back to the theme so the
    /// chrome (sidebar/tabs/status line) tracks the same color as the terminal canvas.
    static func update(
        themeName: String,
        opacity: CGFloat,
        blur: Int = 0,
        appearanceMode: HarnessAppearanceMode = .theme,
        systemAppearance: HarnessSystemAppearance? = nil,
        systemLightThemeName: String? = nil,
        systemDarkThemeName: String? = nil,
        backgroundHex: String? = nil,
        foregroundHex: String? = nil,
        cursorHex: String? = nil
    ) {
        // Resolve through the same single source of truth the terminal surface
        // uses, then derive a recessed frame tint from that canvas.
        let canvas = ThemeManager.resolvedCanvas(
            themeName: themeName,
            appearanceMode: appearanceMode,
            systemAppearance: systemAppearance ?? currentSystemAppearance(),
            systemLightThemeName: systemLightThemeName,
            systemDarkThemeName: systemDarkThemeName,
            customBackgroundHex: backgroundHex,
            customForegroundHex: foregroundHex,
            customCursorHex: cursorHex
        )
        current = HarnessChromePalette.from(
            backgroundHex: canvas.backgroundHex,
            foregroundHex: canvas.foregroundHex,
            cursorHex: canvas.cursorHex
        )
        let storedOpacity = max(0, min(1, opacity))
        backgroundOpacity = storedOpacity
        let system = systemAppearance ?? currentSystemAppearance()
        paintOpacity = CGFloat(ChromeMaterial.paintOpacity(
            stored: Float(storedOpacity),
            appearanceMode: appearanceMode,
            systemAppearance: system
        ))
        backgroundBlur = max(0, min(100, blur))
    }

    static func systemAppearance(from appearance: NSAppearance) -> HarnessSystemAppearance {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private static func currentSystemAppearance() -> HarnessSystemAppearance {
        systemAppearance(from: NSApp.effectiveAppearance)
    }
}
