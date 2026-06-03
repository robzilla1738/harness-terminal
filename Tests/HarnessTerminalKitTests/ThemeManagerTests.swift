import XCTest
import HarnessCore
import HarnessTheme
@testable import HarnessTerminalKit

final class ThemeManagerTests: XCTestCase {
    @MainActor
    func testDefaultBaselinePaletteMatchesMutedANSI16() {
        XCTAssertEqual(ThemeManager.defaultBaselinePaletteHex, [
            "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
            "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
            "#666666", "#d54e53", "#b9ca4a", "#e7c547",
            "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
        ])
        XCTAssertEqual(
            ThemeManager.paletteHex(themeName: ThemeManager.defaultDisplayName),
            ThemeManager.defaultBaselinePaletteHex
        )
    }

    @MainActor
    func testDefaultBaselineIsShippedTheme() {
        let theme = HarnessThemeCatalog.theme(named: ThemeManager.defaultThemeName)

        XCTAssertEqual(ThemeManager.defaultThemeName, "Harness Default")
        XCTAssertEqual(theme?.paletteHex, ThemeManager.defaultBaselinePaletteHex)
        XCTAssertEqual(ThemeManager.paletteHex(themeName: ThemeManager.defaultDisplayName), theme?.paletteHex)
    }

    @MainActor
    func testMacOSSystemAppearanceResolvesConfiguredLightAndDarkThemes() throws {
        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Zenwritten Light"))
        let darkTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Dracula"))

        let light = ThemeManager.resolvedAppearance(
            themeName: "Tokyo Night",
            appearanceMode: .macOSSystem,
            systemAppearance: .light,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Dracula",
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )
        let dark = ThemeManager.resolvedAppearance(
            themeName: "Zenwritten Light",
            appearanceMode: .macOSSystem,
            systemAppearance: .dark,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Dracula",
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )

        XCTAssertEqual(light.canvas.backgroundHex, lightTheme.backgroundHex)
        XCTAssertEqual(light.canvas.foregroundHex, lightTheme.foregroundHex)
        XCTAssertEqual(light.canvas.cursorHex, lightTheme.cursorHex ?? lightTheme.foregroundHex)
        XCTAssertEqual(light.paletteHex, lightTheme.paletteHex)
        XCTAssertEqual(dark.canvas.backgroundHex, darkTheme.backgroundHex)
        XCTAssertEqual(dark.canvas.foregroundHex, darkTheme.foregroundHex)
        XCTAssertEqual(dark.canvas.cursorHex, darkTheme.cursorHex ?? darkTheme.foregroundHex)
        XCTAssertEqual(dark.paletteHex, darkTheme.paletteHex)
    }

    @MainActor
    func testMacOSSystemAppearanceFallsBackToDocumentedDefaultThemes() throws {
        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Zenwritten Light"))
        let darkTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: ThemeManager.defaultThemeName))

        let light = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: .macOSSystem,
            systemAppearance: .light,
            systemLightThemeName: "Missing Light",
            systemDarkThemeName: "Missing Dark",
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )
        let dark = ThemeManager.resolvedAppearance(
            themeName: "Zenwritten Light",
            appearanceMode: .macOSSystem,
            systemAppearance: .dark,
            systemLightThemeName: "Missing Light",
            systemDarkThemeName: "Missing Dark",
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )

        XCTAssertEqual(light.canvas.backgroundHex, lightTheme.backgroundHex)
        XCTAssertEqual(light.paletteHex, lightTheme.paletteHex)
        XCTAssertEqual(dark.canvas.backgroundHex, darkTheme.backgroundHex)
        XCTAssertEqual(dark.paletteHex, darkTheme.paletteHex)
    }

    @MainActor
    func testThemeAppearanceModeIgnoresExplicitSystemAppearance() {
        let lightInput = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: .theme,
            systemAppearance: .light,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Harness Default",
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )
        let darkInput = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: .theme,
            systemAppearance: .dark,
            systemLightThemeName: "GitHub Light",
            systemDarkThemeName: "Tokyo Night",
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )

        XCTAssertEqual(lightInput, darkInput)
        XCTAssertEqual(lightInput.paletteHex, HarnessThemeCatalog.theme(named: "Dracula")?.paletteHex)
        XCTAssertNotEqual(lightInput.paletteHex, ThemeManager.systemLightPaletteHex)
    }

    @MainActor
    func testMacOSSystemAppearanceIgnoresSelectedThemeNameWhenSystemThemeIsUnset() throws {
        let dracula = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: .macOSSystem,
            systemAppearance: .light,
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )
        let zenwritten = ThemeManager.resolvedAppearance(
            themeName: "Zenwritten Light",
            appearanceMode: .macOSSystem,
            systemAppearance: .light,
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )

        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Zenwritten Light"))

        XCTAssertEqual(dracula, zenwritten)
        XCTAssertEqual(dracula.paletteHex, lightTheme.paletteHex)
    }

    @MainActor
    func testMacOSSystemAppearanceKeepsCustomCanvasOverrides() {
        let resolved = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: .macOSSystem,
            systemAppearance: .light,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Harness Default",
            customBackgroundHex: "#123456",
            customForegroundHex: "#ABCDEF",
            customCursorHex: "#FEDCBA"
        )

        XCTAssertEqual(resolved.canvas.backgroundHex, "#123456")
        XCTAssertEqual(resolved.canvas.foregroundHex, "#ABCDEF")
        XCTAssertEqual(resolved.canvas.cursorHex, "#FEDCBA")
        XCTAssertEqual(resolved.paletteHex, HarnessThemeCatalog.theme(named: "Zenwritten Light")?.paletteHex)
    }

    @MainActor
    func testClearingStaleThemeOverridesRevealsSelectedSystemThemeCanvas() throws {
        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Zenwritten Light"))

        var settings = HarnessSettings(
            appearanceMode: .macOSSystem,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Harness Default",
            customBackgroundHex: "#000000",
            customForegroundHex: "#111111",
            customCursorHex: "#222222",
            selectionBackgroundHex: "#333333",
            selectionForegroundHex: "#444444",
            boldColorHex: "#555555",
            cursorTextHex: "#666666",
            dividerHex: "#777777",
            statusLineHex: "#888888"
        )

        let masked = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: settings.appearanceMode,
            systemAppearance: .light,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: settings.customBackgroundHex,
            customForegroundHex: settings.customForegroundHex,
            customCursorHex: settings.customCursorHex
        )
        XCTAssertEqual(masked.canvas.backgroundHex, "#000000")

        settings.clearThemeColorOverrides()
        let unmasked = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: settings.appearanceMode,
            systemAppearance: .light,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: settings.customBackgroundHex,
            customForegroundHex: settings.customForegroundHex,
            customCursorHex: settings.customCursorHex
        )

        XCTAssertEqual(unmasked.canvas.backgroundHex, lightTheme.backgroundHex)
        XCTAssertEqual(unmasked.canvas.foregroundHex, lightTheme.foregroundHex)
        XCTAssertEqual(unmasked.canvas.cursorHex, lightTheme.cursorHex ?? lightTheme.foregroundHex)
    }
}
