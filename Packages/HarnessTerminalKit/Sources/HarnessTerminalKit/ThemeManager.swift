import Foundation
import HarnessCore
import HarnessTheme

@MainActor
public enum ThemeManager {
    public static let defaultThemeName = HarnessThemeCatalog.defaultThemeName

    /// Dropdown entry representing the user's standard terminal baseline.
    /// Terminal output no longer consumes named theme palettes; themes are for
    /// Harness chrome only, so tools such as Claude Code keep their native colors.
    public static let defaultDisplayName = "Default"
    /// Pure black canvas. Under the default 0.63 opacity and blur the desktop reads through it.
    public static let defaultBaselineBackgroundHex = "#000000"
    public static let defaultBaselineForegroundHex = "#ffffff"
    /// Chrome takes its accent from the cursor, so the default chrome stays monochrome.
    public static let defaultBaselineCursorHex = "#ffffff"
    /// Muted ANSI-16 defaults. Used for terminal *output* when theme→output recoloring is off
    /// (the default), so ANSI tools start from a muted baseline instead of the hotter xterm
    /// primaries. Bright black clears 4:1 on the canvas so dim text (comments, hints) stays legible.
    public static let defaultBaselinePaletteHex = [
        "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
        "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
        "#6e6e6e", "#d54e53", "#b9ca4a", "#e7c547",
        "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
    ]

    /// "Harness Light", the fallback when the light theme can't be found.
    public static let systemLightBackgroundHex = "#f8f9fc"
    public static let systemLightForegroundHex = "#1e2430"
    public static let systemLightCursorHex = "#2463d1"
    public static let systemLightPaletteHex = [
        "#1f2533", "#c42b3c", "#2e7d32", "#9a6700",
        "#2463d1", "#8250df", "#12808a", "#d8dce5",
        "#5f6878", "#d73a49", "#3b8f40", "#a86f00",
        "#3d7ef0", "#8f5ee8", "#18858f", "#eef1f6",
    ]
    public static let systemDarkBackgroundHex = defaultBaselineBackgroundHex
    public static let systemDarkForegroundHex = defaultBaselineForegroundHex
    public static let systemDarkCursorHex = defaultBaselineCursorHex
    public static let systemDarkPaletteHex = defaultBaselinePaletteHex
    public static let defaultSystemLightThemeName = "Harness Light"
    public static let defaultSystemDarkThemeName = HarnessThemeCatalog.defaultThemeName

    public static let featuredThemes = [
        HarnessThemeCatalog.defaultThemeName,
        "Harness Light",
        "Harness Navy",
        "Catppuccin Mocha",
        "Dracula",
        "Tokyo Night",
        "Nord",
        "One Dark",
        "Gruvbox Dark",
        "Solarized Dark",
        "Monokai",
        "GitHub Dark",
    ]


    public static func backgroundHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineBackgroundHex }
        return themed(themeName)?.backgroundHex
    }

    public static func foregroundHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineForegroundHex }
        return themed(themeName)?.foregroundHex
    }

    public static func cursorHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineCursorHex }
        return themed(themeName)?.cursorHex
            ?? themed(themeName)?.foregroundHex
    }

    /// The background/foreground/cursor that define the shared canvas. The
    /// terminal surface and the app chrome (sidebar/tabs/status) both resolve
    /// through this so the canvas can never drift between regions.
    public struct ResolvedCanvas: Sendable, Equatable {
        public let backgroundHex: String
        public let foregroundHex: String
        public let cursorHex: String
    }

    public struct ResolvedAppearance: Sendable, Equatable {
        public let canvas: ResolvedCanvas
        public let paletteHex: [String?]
    }

    /// Single source of truth for the canvas colors. Resolution order:
    /// explicit custom hex > Harness appearance mode palette > black baseline.
    public static func resolvedCanvas(
        themeName: String,
        customBackgroundHex: String?,
        customForegroundHex: String?,
        customCursorHex: String?
    ) -> ResolvedCanvas {
        resolvedCanvas(
            themeName: themeName,
            appearanceMode: .theme,
            systemAppearance: .dark,
            systemLightThemeName: nil,
            systemDarkThemeName: nil,
            customBackgroundHex: customBackgroundHex,
            customForegroundHex: customForegroundHex,
            customCursorHex: customCursorHex
        )
    }

    public static func resolvedCanvas(
        themeName: String,
        appearanceMode: HarnessAppearanceMode,
        systemAppearance: HarnessSystemAppearance,
        systemLightThemeName: String? = nil,
        systemDarkThemeName: String? = nil,
        customBackgroundHex: String?,
        customForegroundHex: String?,
        customCursorHex: String?
    ) -> ResolvedCanvas {
        resolvedAppearance(
            themeName: themeName,
            appearanceMode: appearanceMode,
            systemAppearance: systemAppearance,
            systemLightThemeName: systemLightThemeName,
            systemDarkThemeName: systemDarkThemeName,
            customBackgroundHex: customBackgroundHex,
            customForegroundHex: customForegroundHex,
            customCursorHex: customCursorHex
        ).canvas
    }

    public static func resolvedAppearance(
        themeName: String,
        appearanceMode: HarnessAppearanceMode,
        systemAppearance: HarnessSystemAppearance,
        systemLightThemeName: String? = nil,
        systemDarkThemeName: String? = nil,
        customBackgroundHex: String?,
        customForegroundHex: String?,
        customCursorHex: String?
    ) -> ResolvedAppearance {
        let base: ResolvedAppearance
        switch appearanceMode {
        case .theme:
            let fg = foregroundHex(themeName: themeName) ?? defaultBaselineForegroundHex
            base = ResolvedAppearance(
                canvas: ResolvedCanvas(
                    backgroundHex: backgroundHex(themeName: themeName) ?? defaultBaselineBackgroundHex,
                    foregroundHex: fg,
                    cursorHex: cursorHex(themeName: themeName) ?? fg
                ),
                paletteHex: paletteHex(themeName: themeName)
            )
        case .light:
            // Explicit light ignores a stored black canvas override. Otherwise an imported
            // `#000000` would leave light chrome sitting on the dark terminal.
            base = lightAppearance(systemLightThemeName: systemLightThemeName)
        case .macOSSystem:
            if systemAppearance == .light {
                base = lightAppearance(systemLightThemeName: systemLightThemeName)
            } else if let theme = systemTheme(
                systemAppearance: .dark,
                systemLightThemeName: systemLightThemeName,
                systemDarkThemeName: systemDarkThemeName
            ) {
                base = appearance(from: theme)
            } else {
                base = ResolvedAppearance(
                    canvas: ResolvedCanvas(
                        backgroundHex: systemDarkBackgroundHex,
                        foregroundHex: systemDarkForegroundHex,
                        cursorHex: systemDarkCursorHex
                    ),
                    paletteHex: systemPaletteHex(systemAppearance: .dark)
                )
            }
        }
        // `.light` always follows the light theme. Theme mode and follow-system still honor
        // an explicit canvas override.
        let honorCustomCanvas = appearanceMode != .light
        let foreground = (honorCustomCanvas ? customForegroundHex : nil) ?? base.canvas.foregroundHex
        let canvas = ResolvedCanvas(
            backgroundHex: (honorCustomCanvas ? customBackgroundHex : nil) ?? base.canvas.backgroundHex,
            foregroundHex: foreground,
            cursorHex: (honorCustomCanvas ? customCursorHex : nil) ?? base.canvas.cursorHex
        )
        return ResolvedAppearance(canvas: canvas, paletteHex: base.paletteHex)
    }

    /// The existing light theme (the user's light theme, else Harness Light, else the
    /// documented light baseline). Shared by explicit light and a light Mac.
    private static func lightAppearance(systemLightThemeName: String?) -> ResolvedAppearance {
        if let theme = systemTheme(
            systemAppearance: .light,
            systemLightThemeName: systemLightThemeName,
            systemDarkThemeName: nil
        ) {
            return appearance(from: theme)
        }
        return ResolvedAppearance(
            canvas: ResolvedCanvas(
                backgroundHex: systemLightBackgroundHex,
                foregroundHex: systemLightForegroundHex,
                cursorHex: systemLightCursorHex
            ),
            paletteHex: systemPaletteHex(systemAppearance: .light)
        )
    }

    private static func appearance(from theme: HarnessThemeDefinition) -> ResolvedAppearance {
        let foreground = theme.foregroundHex
        return ResolvedAppearance(
            canvas: ResolvedCanvas(
                backgroundHex: theme.backgroundHex,
                foregroundHex: foreground,
                cursorHex: theme.cursorHex ?? foreground
            ),
            paletteHex: theme.paletteHex
        )
    }

    public static func systemPaletteHex(systemAppearance: HarnessSystemAppearance) -> [String?] {
        switch systemAppearance {
        case .light: return systemLightPaletteHex
        case .dark: return systemDarkPaletteHex
        }
    }

    private static func systemTheme(
        systemAppearance: HarnessSystemAppearance,
        systemLightThemeName: String?,
        systemDarkThemeName: String?
    ) -> HarnessThemeDefinition? {
        switch systemAppearance {
        case .light:
            return exactTheme(named: systemLightThemeName)
                ?? exactTheme(named: defaultSystemLightThemeName)
        case .dark:
            return exactTheme(named: systemDarkThemeName)
                ?? exactTheme(named: defaultSystemDarkThemeName)
        }
    }

    private static func exactTheme(named name: String?) -> HarnessThemeDefinition? {
        guard let name else { return nil }
        if name == defaultDisplayName { return HarnessThemeCatalog.theme(named: defaultThemeName) }
        return HarnessThemeCatalog.theme(named: name)
    }

    public static func cursorTextHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineBackgroundHex }
        return themed(themeName)?.cursorTextHex
            ?? themed(themeName)?.backgroundHex
    }

    public static func selectionBackgroundHex(themeName: String) -> String? {
        themed(themeName)?.selectionBackgroundHex
    }

    public static func selectionForegroundHex(themeName: String) -> String? {
        themed(themeName)?.selectionForegroundHex
    }

    /// Bold color is rarely set in themes; fall back to bright-white (palette 15) then
    /// the foreground so the preview swatch in Settings never reads as "missing".
    public static func boldHex(themeName: String) -> String? {
        guard let theme = themed(themeName) else { return nil }
        return theme.paletteHex[15] ?? theme.foregroundHex
    }

    /// 16 ANSI palette colors for settings preview swatches only. TerminalHostView
    /// does not apply these values to the renderer.
    public static func paletteHex(themeName: String) -> [String?] {
        if themeName == defaultDisplayName { return defaultBaselinePaletteHex }
        guard let theme = themed(themeName) else { return Array(repeating: nil, count: 16) }
        return theme.paletteHex
    }

    /// The complete editable color set a named theme contributes. Selecting a
    /// theme seeds these into `HarnessSettings`, after which the user may edit
    /// any of them — the theme is a starting preset, not a live override.
    public struct ThemePreset: Sendable, Equatable {
        public let backgroundHex: String?
        public let foregroundHex: String?
        public let cursorHex: String?
        public let cursorTextHex: String?
        public let selectionBackgroundHex: String?
        public let selectionForegroundHex: String?
        public let boldHex: String?
        public let paletteHex: [String?]
    }

    public static func presetColors(themeName: String) -> ThemePreset {
        ThemePreset(
            backgroundHex: backgroundHex(themeName: themeName),
            foregroundHex: foregroundHex(themeName: themeName),
            cursorHex: cursorHex(themeName: themeName),
            cursorTextHex: cursorTextHex(themeName: themeName),
            selectionBackgroundHex: selectionBackgroundHex(themeName: themeName),
            selectionForegroundHex: selectionForegroundHex(themeName: themeName),
            boldHex: boldHex(themeName: themeName),
            paletteHex: paletteHex(themeName: themeName)
        )
    }

    public static func allThemeNames() -> [String] {
        [defaultDisplayName]
            + featuredThemes
            + HarnessThemeCatalog.allThemes.map(\.name)
                .filter { !featuredThemes.contains($0) && $0 != defaultDisplayName }
    }

    private static func themed(_ name: String) -> HarnessThemeDefinition? {
        let resolved = (name == defaultDisplayName) ? defaultThemeName : name
        return HarnessThemeCatalog.theme(named: resolved) ?? HarnessThemeCatalog.theme(named: defaultThemeName)
    }
}
