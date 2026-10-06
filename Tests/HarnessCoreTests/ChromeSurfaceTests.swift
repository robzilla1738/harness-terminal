import XCTest
@testable import HarnessCore

final class ChromeSurfaceTests: XCTestCase {
    func testIdentityShowsDirectoryAndProgram() {
        let both = SurfaceIdentity.label(directory: "/Users/me/harness", program: "nvim")
        XCTAssertTrue(both.contains("harness"))
        XCTAssertTrue(both.contains("nvim"))
        XCTAssertTrue(both.contains("›"))

        // The login shell is the prompt, not a second path segment.
        let shellOnly = SurfaceIdentity.label(directory: "/Users/me/harness", program: "fish")
        XCTAssertEqual(shellOnly, "harness")
        XCTAssertFalse(shellOnly.contains("fish"))

        let missing = SurfaceIdentity.label(directory: "/Users/me/harness", program: nil)
        let blank = SurfaceIdentity.label(directory: "/Users/me/harness", program: "  ")
        XCTAssertEqual(missing, "harness")
        XCTAssertEqual(blank, missing)
        XCTAssertFalse(missing.contains("fish"))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SurfaceIdentity.label(directory: home, program: "fish"), "~")

        XCTAssertEqual(
            SurfaceIdentity.label(directory: "/Users/me/harness", program: "2.1.291"),
            "harness"
        )
        XCTAssertEqual(
            SurfaceIdentity.label(directory: "/Users/me/harness", program: "2.1.291", agent: "claude"),
            "harness › claude"
        )
        XCTAssertNil(SurfaceIdentity.usableProgram("2.1.291"))
        XCTAssertEqual(SurfaceIdentity.usableProgram("claude"), "claude")

        let nested = SurfaceIdentity.label(directory: home + "/Code/harness", program: "nvim")
        XCTAssertTrue(nested.contains("~/Code/harness"))
        XCTAssertTrue(nested.contains("nvim"))
    }

    func testContrastFloorsHoldForDefaultDarkAndLightPalettes() {
        let dark = ChromePaletteSpec.resolve(backgroundHex: "#000000", foregroundHex: "#ffffff")
        XCTAssertTrue(dark.isDark)
        XCTAssertEqual(dark.surface.hex, "#000000")
        XCTAssertTrue(ChromeContrast.meetsText(dark.textPrimary, on: dark.surface))
        XCTAssertTrue(ChromeContrast.meetsPill(dark.activePillLabel, on: dark.activePillFill))
        XCTAssertGreaterThanOrEqual(dark.textPrimary.contrastRatio(against: dark.surface), ChromeContrast.textMinimum)
        XCTAssertGreaterThanOrEqual(
            dark.activePillLabel.contrastRatio(against: dark.activePillFill),
            ChromeContrast.pillMinimum
        )

        let light = ChromePaletteSpec.resolve(backgroundHex: "#eeeeee", foregroundHex: "#353535")
        XCTAssertFalse(light.isDark)
        XCTAssertLessThan(light.textPrimary.relativeLuminance, light.surface.relativeLuminance)
        XCTAssertTrue(ChromeContrast.meetsText(light.textPrimary, on: light.surface))
        XCTAssertTrue(ChromeContrast.meetsPill(light.activePillLabel, on: light.activePillFill))
    }

    func testLightPaintOpacityDoesNotRewriteTheStoredDefault() {
        let stored: Float = 0.63
        XCTAssertEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .theme, systemAppearance: .light),
            stored,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .theme, systemAppearance: .dark),
            stored,
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .light, systemAppearance: .dark),
            ChromeMaterial.lightPaintOpacityFloor
        )
        XCTAssertGreaterThanOrEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .light),
            ChromeMaterial.lightPaintOpacityFloor
        )
        XCTAssertEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .dark),
            stored,
            accuracy: 0.0001
        )
    }

    func testHeaderTintDoesNotStackOnTheMetalBackdrop() {
        let stored: Float = 0.63
        let themeHeader = ChromeMaterial.headerFillAlpha(stored: stored, appearanceMode: .theme, systemAppearance: .dark)
        let lightHeader = ChromeMaterial.headerFillAlpha(stored: stored, appearanceMode: .light, systemAppearance: .dark)
        XCTAssertEqual(themeHeader, ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .theme, systemAppearance: .dark), accuracy: 0.0001)
        XCTAssertEqual(themeHeader, stored, accuracy: 0.0001)
        XCTAssertEqual(
            lightHeader,
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .light, systemAppearance: .dark),
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(lightHeader, ChromeMaterial.lightPaintOpacityFloor)
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .theme, systemAppearance: .dark))
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .light, systemAppearance: .dark))
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .theme, systemAppearance: .light))
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .light))

        XCTAssertEqual(
            ChromeMaterial.backdropFillAlpha(stored: stored, appearanceMode: .theme, systemAppearance: .dark),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeMaterial.backdropFillAlpha(stored: stored, appearanceMode: .light, systemAppearance: .dark),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeMaterial.backdropFillAlpha(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .light),
            0,
            accuracy: 0.0001
        )
    }

    func testPillsHugLabelsAndSinglePanesStayFlush() {
        let hugged = ChromeLayout.huggedPillWidth(labelWidth: 90, accessoryWidth: 28, min: 72, max: 280)
        XCTAssertEqual(hugged, 118, accuracy: 0.001)
        XCTAssertLessThan(hugged, 280)
        let capped = ChromeLayout.huggedPillWidth(labelWidth: 400, accessoryWidth: 20, min: 72, max: 280)
        XCTAssertEqual(capped, 280, accuracy: 0.001)

        let singleInsets = ChromeLayout.cardInsets(separated: false)
        XCTAssertEqual(singleInsets.leading, 0, accuracy: 0.001)
        XCTAssertEqual(singleInsets.trailing, 0, accuracy: 0.001)
        XCTAssertEqual(singleInsets.bottom, 0, accuracy: 0.001)
        XCTAssertEqual(singleInsets.top, 0, accuracy: 0.001)
        let gaps = ChromeLayout.gapAroundTab(tabBarHeight: 44, pillHeight: 32, cardTopInset: singleInsets.top)
        XCTAssertEqual(gaps.above, gaps.below, accuracy: 0.001)
        XCTAssertEqual(gaps.above, 6, accuracy: 0.001)
        let single = ChromeLayout.island(separated: false, splitRadius: 10)
        XCTAssertEqual(single.margin, singleInsets.top, accuracy: 0.001)
        XCTAssertEqual(single.cornerRadius, 0)
        let splitInsets = ChromeLayout.cardInsets(separated: true)
        XCTAssertEqual(splitInsets.leading, splitInsets.trailing, accuracy: 0.001)
        XCTAssertEqual(splitInsets.leading, splitInsets.bottom, accuracy: 0.001)
        XCTAssertEqual(splitInsets.top, 0, accuracy: 0.001)
        XCTAssertGreaterThan(splitInsets.leading, singleInsets.leading)
        let split = ChromeLayout.island(separated: true, splitRadius: 10)
        XCTAssertEqual(split.margin, splitInsets.top, accuracy: 0.001)
        XCTAssertEqual(split.cornerRadius, 10)

        let widths = [80.0, 140.0, 100.0]
        XCTAssertEqual(ChromeLayout.slotOrigin(index: 1, widths: widths, spacing: 4), 84, accuracy: 0.001)
        XCTAssertEqual(ChromeLayout.slotOrigin(index: 2, widths: widths, spacing: 4), 228, accuracy: 0.001)
        XCTAssertEqual(ChromeLayout.dragTargetSlot(leadingX: 2, widths: widths, spacing: 4), 0)
        XCTAssertEqual(ChromeLayout.dragTargetSlot(leadingX: 82, widths: widths, spacing: 4), 1)
        XCTAssertEqual(ChromeLayout.dragTargetSlot(leadingX: 220, widths: widths, spacing: 4), 2)
    }

    func testLightAppearanceModeRoundTrips() throws {
        let settings = HarnessSettings(appearanceMode: .light)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: data)
        XCTAssertEqual(decoded.appearanceMode, .light)
        XCTAssertEqual(HarnessSettings().appearanceMode, .theme)
    }
}
