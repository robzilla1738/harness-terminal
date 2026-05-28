import XCTest
@testable import HarnessCore

final class HarnessSettingsTests: XCTestCase {
    func testOldSettingsWithCustomHexDoNotSilentlyOverrideThemes() throws {
        let data = Data("""
        {
          "fontSize": 17,
          "fontFamily": "JetBrainsMono Nerd Font",
          "defaultShell": "/bin/zsh",
          "defaultCWD": "/tmp",
          "backgroundOpacity": 0.3,
          "customBackgroundHex": "#000000",
          "customForegroundHex": "#ffffff",
          "useCustomColors": true,
          "boldColorHex": "#eeeeee",
          "minimumContrast": 7,
          "paletteHex": ["#000000", "#ff0000"]
        }
        """.utf8)

        let settings = try JSONDecoder().decode(HarnessSettings.self, from: data)

        XCTAssertFalse(settings.useCustomColors)
        XCTAssertEqual(settings.customBackgroundHex, "#000000")
        XCTAssertEqual(settings.customForegroundHex, "#ffffff")
        XCTAssertNil(settings.boldColorHex)
        XCTAssertEqual(settings.minimumContrast, 1)
        XCTAssertEqual(settings.paletteHex, Array(repeating: nil, count: 16))
    }

    func testImportedGhosttyDefaultsKeepBaseColorsWithoutCustomAnsiMode() {
        let imported = GhosttyImportedDefaults(
            backgroundHex: "#000000",
            foregroundHex: "#ffffff",
            cursorColorHex: "#cccccc"
        )

        let settings = HarnessSettings.makeDefaults(imported: imported)

        XCTAssertFalse(settings.useCustomColors)
        XCTAssertEqual(settings.customBackgroundHex, "#000000")
        XCTAssertEqual(settings.customForegroundHex, "#ffffff")
        XCTAssertEqual(settings.customCursorHex, "#cccccc")
        XCTAssertNil(settings.selectionBackgroundHex)
        XCTAssertNil(settings.selectionForegroundHex)
        XCTAssertNil(settings.boldColorHex)
        XCTAssertNil(settings.cursorTextHex)
        XCTAssertEqual(settings.minimumContrast, 1)
        XCTAssertEqual(settings.paletteHex, Array(repeating: nil, count: 16))
    }

    func testClampedOpacityAllowsFullRangeAboveTinyFloor() {
        // Power-user range: anything from "barely visible" to fully solid is allowed.
        // The 0.05 floor only exists so a slammed-to-zero slider doesn't leave the
        // window completely invisible with no way to find it on screen.
        XCTAssertEqual(HarnessSettings.clampedOpacity(0.01), 0.05, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedOpacity(0.05), 0.05, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedOpacity(0.10), 0.10, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedOpacity(0.30), 0.30, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedOpacity(0.85), 0.85, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedOpacity(1.5), 1.0, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedOpacity(-1.0), 0.05, accuracy: 0.001)
    }

    func testClampedBlurStaysInUsefulRange() {
        XCTAssertEqual(HarnessSettings.clampedBlur(-5), 0)
        XCTAssertEqual(HarnessSettings.clampedBlur(0), 0)
        XCTAssertEqual(HarnessSettings.clampedBlur(20), 20)
        XCTAssertEqual(HarnessSettings.clampedBlur(100), 100)
        XCTAssertEqual(HarnessSettings.clampedBlur(999), 100)
    }

    func testAgentColorOverridesNormalizeAndFallbackToDefaults() throws {
        let data = Data("""
        {
          "agentColorOverrides": {
            "codex": "12abef",
            "claude-code": "#ffeedd",
            "unknown": "#000000",
            "cursor": "not-a-color"
          }
        }
        """.utf8)

        let settings = try JSONDecoder().decode(HarnessSettings.self, from: data)

        XCTAssertEqual(settings.agentColorHex(for: .codex), "#12ABEF")
        XCTAssertEqual(settings.agentColorHex(for: .claudeCode), "#FFEEDD")
        XCTAssertEqual(settings.agentColorHex(for: .cursor), "#5CC8FF")
        XCTAssertNil(settings.agentColorOverrides["unknown"])
    }
}
