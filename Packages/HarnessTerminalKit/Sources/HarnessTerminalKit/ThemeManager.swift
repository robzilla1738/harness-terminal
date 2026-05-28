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
        if let theme = GhosttyThemeCatalog.theme(named: themeName) {
            return theme.background
        }
        return GhosttyThemeCatalog.theme(named: defaultThemeName)?.background
    }

    public static func allThemeNames() -> [String] {
        featuredThemes + GhosttyThemeCatalog.search("").map(\.name).filter { !featuredThemes.contains($0) }
    }
}
