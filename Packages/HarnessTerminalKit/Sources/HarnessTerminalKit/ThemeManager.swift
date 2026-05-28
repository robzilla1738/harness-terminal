import Foundation
import GhosttyTerminal
import GhosttyTheme

@MainActor
public enum ThemeManager {
    public static let defaultThemeName = "Catppuccin Mocha"

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
        if let theme = GhosttyThemeCatalog.theme(named: themeName) {
            _ = controller.setTheme(theme.toTerminalTheme())
            return
        }
        if let theme = GhosttyThemeCatalog.theme(named: "Catppuccin Mocha") {
            _ = controller.setTheme(theme.toTerminalTheme())
        }
    }

    public static func backgroundHex(themeName: String) -> String? {
        themed(themeName)?.background.normalizedHashedHex
    }

    public static func foregroundHex(themeName: String) -> String? {
        themed(themeName)?.foreground.normalizedHashedHex
    }

    public static func cursorHex(themeName: String) -> String? {
        themed(themeName)?.cursorColor?.normalizedHashedHex
            ?? themed(themeName)?.foreground.normalizedHashedHex
    }

    public static func cursorTextHex(themeName: String) -> String? {
        themed(themeName)?.cursorText?.normalizedHashedHex
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

    /// 16 ANSI palette colors for the named theme (`nil` slot = unset).
    public static func paletteHex(themeName: String) -> [String?] {
        guard let theme = themed(themeName) else { return Array(repeating: nil, count: 16) }
        return (0 ..< 16).map { theme.palette[$0]?.normalizedHashedHex }
    }

    public static func allThemeNames() -> [String] {
        featuredThemes + GhosttyThemeCatalog.search("").map(\.name).filter { !featuredThemes.contains($0) }
    }

    private static func themed(_ name: String) -> GhosttyThemeDefinition? {
        GhosttyThemeCatalog.theme(named: name) ?? GhosttyThemeCatalog.theme(named: defaultThemeName)
    }
}

private extension String {
    /// Ghostty themes store hexes without a leading `#`; settings/UI standardize on `#rrggbb`.
    var normalizedHashedHex: String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("#") ? trimmed.lowercased() : "#" + trimmed.lowercased()
    }
}
