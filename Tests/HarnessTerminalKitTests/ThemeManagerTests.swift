import XCTest
import HarnessCore
import HarnessTheme
@testable import HarnessTerminalKit

final class ThemeManagerTests: XCTestCase {
    @MainActor
    func testDefaultBaselinePaletteMatchesGraphite() {
        XCTAssertEqual(ThemeManager.defaultBaselinePaletteHex, [
            "#24282c", "#e58a8a", "#a6bf8e", "#dfbd83",
            "#89afd4", "#b9a0d5", "#89c2c8", "#cbd3d8",
            "#7b878f", "#f2a1a1", "#bed3a5", "#eed09e",
            "#a4c5e5", "#cfbae7", "#a6d8dc", "#f0f4f5",
        ])
        XCTAssertEqual(
            ThemeManager.paletteHex(themeName: ThemeManager.defaultDisplayName),
            ThemeManager.defaultBaselinePaletteHex
        )
    }

    @MainActor
    func testDefaultBaselineIsShippedTheme() {
        let theme = HarnessThemeCatalog.theme(named: ThemeManager.defaultThemeName)

        XCTAssertEqual(ThemeManager.defaultThemeName, "Harness Graphite")
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
        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: ThemeManager.defaultSystemLightThemeName))
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

        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: ThemeManager.defaultSystemLightThemeName))

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

    @MainActor
    func testFreshSettingsResolveGraphiteCanvas() {
        let settings = HarnessSettings()
        XCTAssertEqual(settings.appearanceMode, .theme)
        XCTAssertEqual(settings.backgroundOpacity, 0.63, accuracy: 0.0001)
        XCTAssertEqual(settings.backgroundBlur, 16)

        let canvas = ThemeManager.resolvedCanvas(
            themeName: "Default",
            appearanceMode: settings.appearanceMode,
            systemAppearance: .light,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: settings.customBackgroundHex,
            customForegroundHex: settings.customForegroundHex,
            customCursorHex: settings.customCursorHex
        )
        XCTAssertEqual(canvas.backgroundHex.lowercased(), ThemeManager.defaultBaselineBackgroundHex)
        let palette = ChromePaletteSpec.resolve(backgroundHex: canvas.backgroundHex, foregroundHex: canvas.foregroundHex)
        XCTAssertTrue(palette.isDark)
        XCTAssertEqual(palette.surface.hex, ThemeManager.defaultBaselineBackgroundHex)
        XCTAssertFalse(palette.surface.perceivedBrightness > 0.5)
    }

    @MainActor
    func testExplicitLightAndFollowSystemShareALightCanvasThenDefaultRestoresBlack() throws {
        let settings = HarnessSettings()
        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: settings.systemLightThemeName))

        let explicit = ThemeManager.resolvedAppearance(
            themeName: "Default",
            appearanceMode: .light,
            systemAppearance: .dark,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: "#000000",
            customForegroundHex: "#ffffff",
            customCursorHex: "#ffffff"
        )
        let follow = ThemeManager.resolvedAppearance(
            themeName: "Dracula",
            appearanceMode: .macOSSystem,
            systemAppearance: .light,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )

        XCTAssertEqual(explicit.canvas.backgroundHex, lightTheme.backgroundHex)
        XCTAssertEqual(explicit.canvas.foregroundHex, lightTheme.foregroundHex)
        XCTAssertEqual(follow.canvas.backgroundHex, explicit.canvas.backgroundHex)
        XCTAssertEqual(follow.canvas.foregroundHex, explicit.canvas.foregroundHex)

        let lightPalette = ChromePaletteSpec.resolve(
            backgroundHex: explicit.canvas.backgroundHex,
            foregroundHex: explicit.canvas.foregroundHex
        )
        XCTAssertFalse(lightPalette.isDark)
        XCTAssertLessThan(lightPalette.textPrimary.relativeLuminance, lightPalette.surface.relativeLuminance)
        XCTAssertTrue(ChromeContrast.meetsText(lightPalette.textPrimary, on: lightPalette.surface))
        XCTAssertTrue(ChromeContrast.meetsPill(lightPalette.activePillLabel, on: lightPalette.activePillFill))

        let restored = ThemeManager.resolvedCanvas(
            themeName: "Default",
            appearanceMode: .theme,
            systemAppearance: .light,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )
        let restoredPalette = ChromePaletteSpec.resolve(
            backgroundHex: restored.backgroundHex,
            foregroundHex: restored.foregroundHex
        )
        XCTAssertEqual(restored.backgroundHex.lowercased(), ThemeManager.defaultBaselineBackgroundHex)
        XCTAssertTrue(restoredPalette.isDark)
        XCTAssertEqual(restoredPalette.surface.hex, ThemeManager.defaultBaselineBackgroundHex)
    }

    @MainActor
    func testGraphiteDefaultIsReadable() throws {
        let background = try XCTUnwrap(ChromeColor(hex: ThemeManager.defaultBaselineBackgroundHex))
        let foreground = try XCTUnwrap(ChromeColor(hex: ThemeManager.defaultBaselineForegroundHex))
        XCTAssertGreaterThanOrEqual(foreground.contrastRatio(against: background), 7, "body text clears WCAG AAA")
        let cursor = try XCTUnwrap(ChromeColor(hex: ThemeManager.defaultBaselineCursorHex))
        XCTAssertGreaterThanOrEqual(cursor.contrastRatio(against: background), 4.5)
        // Every non-black ANSI color reads on the canvas; bright black (dim text) clears 4:1.
        for (index, hex) in ThemeManager.defaultBaselinePaletteHex.enumerated() where index != 0 {
            let color = try XCTUnwrap(ChromeColor(hex: hex))
            XCTAssertGreaterThanOrEqual(color.contrastRatio(against: background), 4, "palette \(index) \(hex)")
        }
        let theme = try XCTUnwrap(HarnessThemeCatalog.theme(named: HarnessThemeCatalog.defaultThemeName))
        XCTAssertEqual(theme.backgroundHex.lowercased(), ThemeManager.defaultBaselineBackgroundHex)
        XCTAssertNotNil(HarnessThemeCatalog.theme(named: "Harness Navy"))
    }
}

final class HarnessLightReadabilityTests: XCTestCase {
    @MainActor
    func testOriginalThemePresetsAreFeaturedAndReadable() throws {
        let originals = HarnessThemeCatalog.allThemes.filter { HarnessThemeCatalog.isBuiltin($0.name) && $0.name.hasPrefix("Harness ") }
        XCTAssertEqual(originals.count, 25)
        XCTAssertEqual(Array(ThemeManager.featuredThemes.prefix(25)), originals.map(\.name))
        for theme in originals {
            let preset = ThemeManager.presetColors(themeName: theme.name)
            XCTAssertEqual(preset.backgroundHex, theme.backgroundHex)
            XCTAssertEqual(preset.paletteHex, theme.paletteHex)
            let background = try XCTUnwrap(ChromeColor(hex: theme.backgroundHex))
            let foreground = try XCTUnwrap(ChromeColor(hex: theme.foregroundHex))
            let cursor = try XCTUnwrap(theme.cursorHex.flatMap(ChromeColor.init(hex:)))
            let selection = try XCTUnwrap(theme.selectionBackgroundHex.flatMap(ChromeColor.init(hex:)))
            XCTAssertGreaterThanOrEqual(foreground.contrastRatio(against: background), 7, theme.name)
            XCTAssertGreaterThanOrEqual(foreground.contrastRatio(against: selection), 4.5, theme.name)
            XCTAssertGreaterThanOrEqual(cursor.contrastRatio(against: background), 3, theme.name)
            // Preserve the original Light palette; new palettes meet the stronger text floor.
            let minimum = theme.name == "Harness Light" ? 3.5 : 4.5
            for index in [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14] {
                let color = try XCTUnwrap(ChromeColor(hex: theme.palette[index].hexString))
                XCTAssertGreaterThanOrEqual(color.contrastRatio(against: background), minimum, "\(theme.name) ANSI \(index)")
            }
            let chrome = ChromePaletteSpec.resolve(backgroundHex: theme.backgroundHex, foregroundHex: theme.foregroundHex)
            XCTAssertTrue(ChromeContrast.meetsText(chrome.textPrimary, on: chrome.surface), theme.name)
            XCTAssertTrue(ChromeContrast.meetsPill(chrome.activePillLabel, on: chrome.activePillFill), theme.name)
        }
    }

    func testHarnessLightIsCrispAndEveryInkColorReads() throws {
        let theme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Harness Light"))
        let background = try XCTUnwrap(ChromeColor(hex: theme.backgroundHex))
        let foreground = try XCTUnwrap(ChromeColor(hex: theme.foregroundHex))
        XCTAssertGreaterThanOrEqual(foreground.contrastRatio(against: background), 12)
        // 0 is the dark ink; 7 and 15 are the light "white" slots, not text on this canvas.
        for (index, hex) in theme.paletteHex.enumerated() where ![7, 15].contains(index) {
            let color = try XCTUnwrap(hex.flatMap(ChromeColor.init(hex:)))
            XCTAssertGreaterThanOrEqual(color.contrastRatio(against: background), 3.5, "palette \(index)")
        }
    }
}
