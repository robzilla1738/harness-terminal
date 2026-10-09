import XCTest
@testable import HarnessApp
import HarnessCore
import HarnessTerminalKit

@MainActor
final class AppearanceChromeTests: XCTestCase {
    func testChromeFollowsLightThenRestoresTheBlackDefault() {
        let settings = HarnessSettings()
        XCTAssertEqual(settings.appearanceMode, .theme)
        XCTAssertEqual(settings.backgroundOpacity, 0.63, accuracy: 0.0001)
        XCTAssertEqual(settings.backgroundBlur, 16)

        apply(settings: settings, themeName: "Default", mode: .theme, system: .light)
        XCTAssertTrue(HarnessChrome.current.isDark)
        XCTAssertEqual(HarnessChrome.backgroundOpacity, 0.63, accuracy: 0.0001)
        XCTAssertEqual(HarnessChrome.backgroundBlur, 16)
        XCTAssertEqual(HarnessChrome.paintOpacity, 0.63, accuracy: 0.0001)
        assertHex(HarnessChrome.current.terminalBackground, ThemeManager.defaultBaselineBackgroundHex)
        assertHex(HarnessChrome.current.sidebarBackground, ThemeManager.defaultBaselineBackgroundHex)
        assertHex(HarnessChrome.current.accent, ThemeManager.defaultBaselineCursorHex)

        let lightCanvas = ThemeManager.resolvedCanvas(
            themeName: "Default",
            appearanceMode: .light,
            systemAppearance: .dark,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: "#000000",
            customForegroundHex: "#ffffff",
            customCursorHex: nil
        )
        apply(
            settings: settings,
            themeName: "Default",
            mode: .light,
            system: .dark,
            backgroundHex: "#000000",
            foregroundHex: "#ffffff"
        )
        XCTAssertFalse(HarnessChrome.current.isDark)
        XCTAssertEqual(settings.backgroundOpacity, 0.63, accuracy: 0.0001)
        XCTAssertEqual(settings.backgroundBlur, 16)
        XCTAssertEqual(HarnessChrome.backgroundOpacity, 0.63, accuracy: 0.0001)
        XCTAssertEqual(HarnessChrome.backgroundBlur, 16)
        XCTAssertGreaterThanOrEqual(HarnessChrome.paintOpacity, CGFloat(ChromeMaterial.lightPaintOpacityFloor))
        assertHex(HarnessChrome.current.terminalBackground, lightCanvas.backgroundHex)
        assertDarker(
            HarnessChrome.current.textPrimary,
            than: HarnessChrome.current.terminalBackground
        )
        assertContrast(HarnessChrome.current)

        apply(settings: settings, themeName: "Dracula", mode: .macOSSystem, system: .light)
        XCTAssertFalse(HarnessChrome.current.isDark)
        assertHex(HarnessChrome.current.terminalBackground, lightCanvas.backgroundHex)
        assertDarker(
            HarnessChrome.current.textPrimary,
            than: HarnessChrome.current.terminalBackground
        )

        apply(settings: settings, themeName: "Default", mode: .theme, system: .light)
        XCTAssertTrue(HarnessChrome.current.isDark)
        XCTAssertEqual(HarnessChrome.backgroundOpacity, 0.63, accuracy: 0.0001)
        XCTAssertEqual(HarnessChrome.paintOpacity, 0.63, accuracy: 0.0001)
        XCTAssertEqual(HarnessChrome.backgroundBlur, 16)
        assertHex(HarnessChrome.current.terminalBackground, ThemeManager.defaultBaselineBackgroundHex)
        assertHex(HarnessChrome.current.sidebarBackground, ThemeManager.defaultBaselineBackgroundHex)
        assertHex(HarnessChrome.current.accent, ThemeManager.defaultBaselineCursorHex)
    }

    private func apply(
        settings: HarnessSettings,
        themeName: String,
        mode: HarnessAppearanceMode,
        system: HarnessSystemAppearance,
        backgroundHex: String? = nil,
        foregroundHex: String? = nil
    ) {
        HarnessChrome.update(
            themeName: themeName,
            opacity: CGFloat(settings.backgroundOpacity),
            blur: settings.backgroundBlur,
            appearanceMode: mode,
            systemAppearance: system,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            backgroundHex: backgroundHex,
            foregroundHex: foregroundHex,
            cursorHex: nil
        )
    }

    private func assertHex(_ color: NSColor, _ hex: String) {
        let expected = tryUnwrapRGB(NSColor.fromHex(hex) ?? .white)
        let rgb = tryUnwrapRGB(color)
        XCTAssertEqual(rgb.redComponent, expected.redComponent, accuracy: 0.02)
        XCTAssertEqual(rgb.greenComponent, expected.greenComponent, accuracy: 0.02)
        XCTAssertEqual(rgb.blueComponent, expected.blueComponent, accuracy: 0.02)
    }

    private func assertDarker(_ text: NSColor, than surface: NSColor) {
        XCTAssertLessThan(luminance(text), luminance(surface))
    }

    private func assertContrast(_ palette: HarnessChromePalette) {
        let surface = chromeColor(palette.terminalBackground)
        let text = chromeColor(palette.textPrimary)
        let pill = chromeColor(palette.activePillFill)
        let pillLabel = chromeColor(palette.activePillLabel)
        XCTAssertTrue(ChromeContrast.meetsText(text, on: surface))
        XCTAssertTrue(ChromeContrast.meetsPill(pillLabel, on: pill))
        if !palette.isDark {
            // Light secondary/tertiary are opaque so glyph edges don't fringe.
            XCTAssertEqual(palette.textSecondary.alphaComponent, 1, accuracy: 0.001)
            XCTAssertEqual(palette.textTertiary.alphaComponent, 1, accuracy: 0.001)
            let secondary = chromeColor(palette.textSecondary)
            let tertiary = chromeColor(palette.textTertiary)
            XCTAssertTrue(ChromeContrast.meetsText(secondary, on: surface))
            XCTAssertGreaterThanOrEqual(tertiary.contrastRatio(against: surface), 3)
        }
    }

    private func chromeColor(_ color: NSColor) -> ChromeColor {
        let rgb = tryUnwrapRGB(color)
        return ChromeColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    private func luminance(_ color: NSColor) -> Double {
        chromeColor(color).relativeLuminance
    }

    private func tryUnwrapRGB(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.sRGB) ?? color
    }
    func testPaneDividerRemainsDraggableWhenAppKitProposesEmptyHitRect() {
        let split = HarnessSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        split.isVertical = true
        split.addSubview(NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 400)))
        split.addSubview(NSView(frame: NSRect(x: 300, y: 0, width: 300, height: 400)))
        let vertical = split.splitView(split, effectiveRect: .zero, forDrawnRect: .zero, ofDividerAt: 0)
        XCTAssertEqual(vertical.height, 400)
        XCTAssertGreaterThanOrEqual(vertical.width, 8)
        XCTAssertTrue(vertical.contains(NSPoint(x: 300, y: 200)))
        split.isVertical = false
        split.subviews[0].frame = NSRect(x: 0, y: 200, width: 600, height: 200)
        let horizontal = split.splitView(split, effectiveRect: .zero, forDrawnRect: .zero, ofDividerAt: 0)
        XCTAssertEqual(horizontal.width, 600)
        XCTAssertGreaterThanOrEqual(horizontal.height, 8)
    }

}
