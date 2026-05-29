import Foundation
import GhosttyTerminal
import GhosttyTheme

@MainActor
public enum ThemeManager {
    public static let defaultThemeName = "Catppuccin Mocha"

    /// Dropdown entry representing the user's Ghostty-like terminal baseline.
    /// Terminal output no longer consumes named theme palettes; themes are for
    /// Harness chrome only, so tools such as Claude Code keep their native colors.
    public static let defaultDisplayName = "Default"
    public static let defaultBaselineBackgroundHex = "#000000"
    public static let defaultBaselineForegroundHex = "#ffffff"
    public static let defaultBaselinePaletteHex = [
        "#1D1F21", "#CC6666", "#B5BD68", "#F0C674",
        "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
        "#666666", "#D54E53", "#B9CA4A", "#E7C547",
        "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA",
    ]

    /// Black/white baseline used by older callers. It deliberately does not set
    /// ANSI palette entries; libghostty/Ghostty should own terminal tool colors.
    private static func defaultBaselineTheme() -> TerminalTheme {
        let config = TerminalConfiguration {
            $0.withBackground(defaultBaselineBackgroundHex)
            $0.withForeground(defaultBaselineForegroundHex)
        }
        return TerminalTheme(light: config, dark: config)
    }

    public static let featuredThemes = [
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

    public static func apply(themeName: String, to controller: TerminalController) {
        if themeName == defaultDisplayName {
            _ = controller.setTheme(defaultBaselineTheme())
            return
        }
        if let theme = GhosttyThemeCatalog.theme(named: themeName) {
            _ = controller.setTheme(theme.toTerminalTheme())
            return
        }
        if let theme = GhosttyThemeCatalog.theme(named: defaultThemeName) {
            _ = controller.setTheme(theme.toTerminalTheme())
        }
    }

    /// Terminal output intentionally ignores Harness themes. Themes may style
    /// chrome previews, tabs, sidebar, etc.; libghostty/Ghostty own ANSI and
    /// truecolor rendering so terminal tools are not retinted by Harness.
    public static func configureBuilder(_ builder: inout TerminalConfiguration.Builder, themeName: String) {}

    public static func backgroundHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineBackgroundHex }
        return themed(themeName)?.background.normalizedHashedHex
    }

    public static func foregroundHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineForegroundHex }
        return themed(themeName)?.foreground.normalizedHashedHex
    }

    public static func cursorHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineForegroundHex }
        return themed(themeName)?.cursorColor?.normalizedHashedHex
            ?? themed(themeName)?.foreground.normalizedHashedHex
    }

    /// The background/foreground/cursor that define the shared canvas. The
    /// terminal surface and the app chrome (sidebar/tabs/status) both resolve
    /// through this so the canvas can never drift between regions.
    public struct ResolvedCanvas: Sendable, Equatable {
        public let backgroundHex: String
        public let foregroundHex: String
        public let cursorHex: String
    }

    /// Single source of truth for the canvas colors. Resolution order:
    /// explicit custom hex > named theme preset > black/white baseline.
    public static func resolvedCanvas(
        themeName: String,
        customBackgroundHex: String?,
        customForegroundHex: String?,
        customCursorHex: String?
    ) -> ResolvedCanvas {
        let bg = customBackgroundHex ?? backgroundHex(themeName: themeName) ?? defaultBaselineBackgroundHex
        let fg = customForegroundHex ?? foregroundHex(themeName: themeName) ?? defaultBaselineForegroundHex
        let cursor = customCursorHex ?? cursorHex(themeName: themeName) ?? fg
        return ResolvedCanvas(backgroundHex: bg, foregroundHex: fg, cursorHex: cursor)
    }

    public static func cursorTextHex(themeName: String) -> String? {
        if themeName == defaultDisplayName { return defaultBaselineBackgroundHex }
        return themed(themeName)?.cursorText?.normalizedHashedHex
            ?? themed(themeName)?.background.normalizedHashedHex
    }

    public static func selectionBackgroundHex(themeName: String) -> String? {
        themed(themeName)?.selectionBackground?.normalizedHashedHex
    }

    public static func selectionForegroundHex(themeName: String) -> String? {
        themed(themeName)?.selectionForeground?.normalizedHashedHex
    }

    /// Bold color is rarely set in themes; fall back to the foreground so the
    /// preview swatch in Settings never reads as "missing".
    public static func boldHex(themeName: String) -> String? {
        themed(themeName)?.palette[15]?.normalizedHashedHex
            ?? themed(themeName)?.foreground.normalizedHashedHex
    }

    /// 16 ANSI palette colors for settings preview swatches only. TerminalHostView
    /// does not apply these values to libghostty.
    public static func paletteHex(themeName: String) -> [String?] {
        if themeName == defaultDisplayName { return defaultBaselinePaletteHex }
        guard let theme = themed(themeName) else { return Array(repeating: nil, count: 16) }
        return (0 ..< 16).map { theme.palette[$0]?.normalizedHashedHex }
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
            + GhosttyThemeCatalog.search("").map(\.name)
                .filter { !featuredThemes.contains($0) && $0 != defaultDisplayName }
    }

    private static func themed(_ name: String) -> GhosttyThemeDefinition? {
        let resolved = (name == defaultDisplayName) ? defaultThemeName : name
        return GhosttyThemeCatalog.theme(named: resolved) ?? GhosttyThemeCatalog.theme(named: defaultThemeName)
    }
}

private extension String {
    /// Ghostty themes store hexes without a leading `#`; settings/UI standardize on `#rrggbb`.
    var normalizedHashedHex: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("#") ? trimmed.lowercased() : "#" + trimmed.lowercased()
    }
}
