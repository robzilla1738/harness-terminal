import XCTest
@testable import HarnessCore
@testable import HarnessTerminalKit
import HarnessTerminalEngine
import HarnessTerminalRenderer
import HarnessTheme

@MainActor
final class AppearancePaletteTests: XCTestCase {
    func testLightModeFirmsPaintOpacity() {
        let stored: Float = 0.25
        let light = ChromeMaterial.paintOpacity(
            stored: stored,
            appearanceMode: .light,
            systemAppearance: .dark
        )
        XCTAssertEqual(light, 0.94, accuracy: 0.001)
        let theme = ChromeMaterial.paintOpacity(
            stored: stored,
            appearanceMode: .theme,
            systemAppearance: .dark
        )
        XCTAssertEqual(theme, stored, accuracy: 0.001)
    }

    func testTruecolorPassesThroughUnchanged() {
        let gray = HarnessTheme.RGBColor(red: 1, green: 2, blue: 3)
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: (0 ..< 16).map { _ in gray }),
            defaultForeground: HarnessTheme.RGBColor(red: 9, green: 9, blue: 9),
            defaultBackground: HarnessTheme.RGBColor(red: 0, green: 0, blue: 0)
        )
        let rgb = resolver.resolved(
            .rgb(r: 215, g: 119, b: 87),
            default: HarnessTheme.RGBColor(red: 1, green: 1, blue: 1)
        )
        XCTAssertEqual(rgb.red, 215)
        XCTAssertEqual(rgb.green, 119)
        XCTAssertEqual(rgb.blue, 87)
    }

    func testLightModeUsesLightPaletteNotStoredDarkPalette() {
        var settings = HarnessSettings()
        settings.appearanceMode = .light
        settings.systemLightThemeName = "Zenwritten Light"
        settings.paletteHex = Array(repeating: "#EF6560", count: 16)
        let resolved = TerminalHostView.resolvedNativeAppearance(
            themeName: "Default",
            settings: settings,
            systemAppearance: .light
        )
        XCTAssertEqual(resolved.outputPaletteHex.count, 16)
        XCTAssertFalse(resolved.outputPaletteHex.contains("#EF6560"))
        XCTAssertEqual(resolved.outputPaletteHex[1], Optional("#a8334c"))
        XCTAssertEqual(resolved.canvasForegroundHex.lowercased(), "#353535")
    }

    func testLightCanvasTakesSelectionFromTheLightTheme() {
        // A light canvas must use the light selection even when the snapshot names Default.
        var settings = HarnessSettings()
        settings.appearanceMode = .light
        let light = TerminalHostView.resolvedNativeAppearance(themeName: "Default", settings: settings, systemAppearance: .dark)
        XCTAssertEqual(light.selectionBackgroundHex?.lowercased(), "#cddcf7")

        settings.appearanceMode = .theme
        let dark = TerminalHostView.resolvedNativeAppearance(themeName: "Default", settings: settings, systemAppearance: .light)
        XCTAssertEqual(dark.selectionBackgroundHex?.lowercased(), "#343d44")
    }

    func testThemeModeExplicitPaletteFillsOnlyEmptySlots() {
        var settings = HarnessSettings()
        settings.appearanceMode = .theme
        settings.applyThemeToTerminalOutput = true
        var slots = Array<String?>(repeating: nil, count: 16)
        slots[1] = "#EF6560"
        settings.paletteHex = slots
        let resolved = TerminalHostView.resolvedNativeAppearance(
            themeName: "Default",
            settings: settings,
            systemAppearance: .dark
        )
        XCTAssertEqual(resolved.outputPaletteHex[1]?.lowercased(), "#ef6560")
        let themeRed = ThemeManager.resolvedAppearance(
            themeName: "Default",
            appearanceMode: .theme,
            systemAppearance: .dark,
            systemLightThemeName: nil,
            systemDarkThemeName: nil,
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        ).paletteHex[0]
        XCTAssertEqual(resolved.outputPaletteHex[0], themeRed)
    }

    func testFollowMacOSLightUsesLightPaletteNotStoredDarkPalette() {
        var settings = HarnessSettings()
        settings.appearanceMode = .macOSSystem
        settings.systemLightThemeName = "Zenwritten Light"
        settings.applyThemeToTerminalOutput = true
        settings.paletteHex = Array(repeating: "#EF6560", count: 16)
        let resolved = TerminalHostView.resolvedNativeAppearance(
            themeName: "Default",
            settings: settings,
            systemAppearance: .light
        )
        XCTAssertEqual(resolved.outputPaletteHex[1], Optional("#a8334c"))
        XCTAssertFalse(resolved.outputPaletteHex.contains("#EF6560"))
    }

    func testExplicitPaletteFillsEmptySlotsOnlyInThemeMode() {
        var settings = HarnessSettings()
        settings.appearanceMode = .macOSSystem
        settings.applyThemeToTerminalOutput = true
        var slots = Array<String?>(repeating: nil, count: 16)
        slots[1] = "#EF6560"
        settings.paletteHex = slots
        let resolved = TerminalHostView.resolvedNativeAppearance(
            themeName: "Default",
            settings: settings,
            systemAppearance: .dark
        )
        XCTAssertEqual(resolved.outputPaletteHex[1]?.lowercased(), "#ef6560")
        XCTAssertNil(resolved.outputPaletteHex[0])
    }

    func testCompactIsFlushAndComfortableIsAnInsetCard() {
        let single = ChromeLayout.cardInsets(separated: false)
        XCTAssertEqual(single.top, 0)
        XCTAssertEqual(single.leading, 0)
        XCTAssertEqual(single.bottom, 0)
        XCTAssertEqual(single.trailing, 0)
        XCTAssertEqual(ChromeLayout.island(separated: false, splitRadius: 10).cornerRadius, 0)
        let split = ChromeLayout.cardInsets(separated: true)
        XCTAssertEqual(split.leading, ChromeLayout.islandGap / 2)
        XCTAssertEqual(split.top, ChromeLayout.islandGap / 2)
        XCTAssertEqual(ChromeLayout.island(separated: true, splitRadius: 10).cornerRadius, 10)
    }

    func testGUIHistoryDoesNotExceedDaemonByteCap() {
        let ceiling = TerminalHostView.historyLineCap(daemonScrollbackBytes: 0)
        XCTAssertEqual(ceiling, ScrollbackBudget.unlimitedSafetyCapBytes / ScrollbackBudget.bytesPerLine)
        XCTAssertGreaterThan(ceiling, 1)
        XCTAssertEqual(TerminalHostView.historyLineCap(daemonScrollbackBytes: 160 * 4), 4)
        // Cap 3 has zero trim slack (`maxHistoryLines / 4`), so the retained history
        // settles on the cap instead of the one-line amortized overshoot.
        let cap = TerminalHostView.historyLineCap(daemonScrollbackBytes: 160 * 3)
        XCTAssertEqual(cap, 3)
        let term = TerminalEmulator(cols: 40, rows: 4)
        term.maxScrollbackLines = cap
        var script = ""
        for i in 0 ..< 40 {
            script += "line-\(i)\r\n"
        }
        term.feed(script)
        XCTAssertLessThanOrEqual(term.historyCount, cap)
    }
}
