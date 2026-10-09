import Foundation
import HarnessCore
import HarnessRemoteProtocol
import HarnessTheme

/// Resolves stored host appearance, including imported themes and explicit palette slots.
/// Linux has no system-appearance signal; its follow-system default is the configured dark half.
enum MobileAppearance {
    static func resolve(themeName: String) throws -> RemoteAppearance {
        let settings = HarnessSettings.load()
        #if os(macOS)
        let isLight = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
        #else
        let isLight = false
        #endif
        let selected: String
        switch settings.appearanceMode {
        case .theme: selected = themeName == "Default" ? HarnessThemeCatalog.defaultThemeName : themeName
        case .light: selected = settings.systemLightThemeName
        case .macOSSystem: selected = isLight ? settings.systemLightThemeName : settings.systemDarkThemeName
        }
        let documents = try ThemeFileService().installedThemes(in: HarnessPaths.themesDirectory)
        let fallback = settings.appearanceMode == .light || (settings.appearanceMode == .macOSSystem && isLight) ? "Harness Light" : HarnessThemeCatalog.defaultThemeName
        guard let theme = documents.first(where: { $0.name == selected }).map(HarnessThemeDefinition.init(document:))
                ?? HarnessThemeCatalog.theme(named: selected) ?? HarnessThemeCatalog.theme(named: fallback) else {
            throw RemoteFailure(code: "appearanceUnavailable", message: "The host theme could not be resolved")
        }
        func hex(_ override: String?, _ fallback: String?) -> String? {
            override.flatMap { HarnessTheme.RGBColor(hex: $0)?.hexString } ?? fallback
        }
        let honorCustomCanvas = settings.appearanceMode != .light
        let foreground = hex(honorCustomCanvas ? settings.customForegroundHex : nil, theme.foregroundHex) ?? theme.foregroundHex
        return RemoteAppearance(themeName: theme.name,
            background: hex(honorCustomCanvas ? settings.customBackgroundHex : nil, theme.backgroundHex) ?? theme.backgroundHex,
            foreground: foreground, cursor: hex(honorCustomCanvas ? settings.customCursorHex : nil, theme.cursorHex) ?? foreground,
            cursorText: hex(settings.cursorTextHex, theme.cursorTextHex),
            selectionBackground: hex(settings.selectionBackgroundHex, theme.selectionBackgroundHex),
            selectionForeground: hex(settings.selectionForegroundHex, theme.selectionForegroundHex), bold: hex(settings.boldColorHex, theme.boldHex),
            palette: (0..<16).map { index in
                hex(index < settings.paletteHex.count ? settings.paletteHex[index] : nil, theme.palette[index].hexString) ?? theme.palette[index].hexString
            }, colorRendering: settings.colorRendering.rawValue, textRendering: settings.textRendering.rawValue)
    }
}
