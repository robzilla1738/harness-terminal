import AppKit
import HarnessCore
import HarnessTerminalKit
import HarnessTheme

/// The themes folder as part of the theme menu: saved and imported `.harnesstheme` files list
/// beside the built-in themes, and the current colors can be saved there or exported.
@MainActor
enum ThemeLibrary {
    private static let files = ThemeFileService()

    /// Read the themes folder into the catalog. Called at launch and after every save.
    static func reload() {
        let documents = (try? files.installedThemes(in: HarnessPaths.themesDirectory)) ?? []
        HarnessThemeCatalog.userThemes = documents.map(HarnessThemeDefinition.init(document:))
    }

    /// The colors on screen now: each override from Settings, else the theme's own.
    static func currentDocument(named name: String) -> ThemeDocument? {
        let settings = SessionCoordinator.shared.settings
        let theme = SessionCoordinator.shared.snapshot.themeName
        func color(_ override: String?, _ fallback: String?) -> HarnessTheme.RGBColor? {
            (override ?? fallback).flatMap { HarnessTheme.RGBColor(hex: $0) }
        }
        let themePalette = ThemeManager.paletteHex(themeName: theme)
        let palette = (0 ..< 16).compactMap { index in
            color(index < settings.paletteHex.count ? settings.paletteHex[index] : nil,
                  index < themePalette.count ? themePalette[index] : nil)
        }
        guard let background = color(settings.customBackgroundHex, ThemeManager.backgroundHex(themeName: theme)),
              let foreground = color(settings.customForegroundHex, ThemeManager.foregroundHex(themeName: theme)),
              palette.count == 16
        else { return nil }
        return ThemeDocument(name: name, colors: ThemeDocument.Colors(
            background: background,
            foreground: foreground,
            cursor: color(settings.customCursorHex, ThemeManager.cursorHex(themeName: theme)),
            cursorText: color(settings.cursorTextHex, ThemeManager.cursorTextHex(themeName: theme)),
            selectionBackground: color(settings.selectionBackgroundHex, ThemeManager.selectionBackgroundHex(themeName: theme)),
            selectionForeground: color(settings.selectionForegroundHex, ThemeManager.selectionForegroundHex(themeName: theme)),
            bold: color(settings.boldColorHex, ThemeManager.boldHex(themeName: theme)),
            palette: palette
        ))
    }

    /// Save the current colors as a theme in the themes folder, then switch to it so it shows
    /// as the selected theme (its colors are the same, so nothing on screen changes).
    static func saveCurrent(as name: String) throws {
        guard let document = currentDocument(named: name) else { throw CocoaError(.fileWriteUnknown) }
        _ = try files.install(document, into: HarnessPaths.themesDirectory)
        reload()
        SessionCoordinator.shared.setTheme(name)
    }

    static func exportCurrent(to url: URL, named name: String) throws {
        guard let document = currentDocument(named: name) else { throw CocoaError(.fileWriteUnknown) }
        try files.export(document, to: url)
    }
}
