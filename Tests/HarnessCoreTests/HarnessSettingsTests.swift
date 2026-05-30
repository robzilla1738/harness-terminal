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
          "customForegroundHex": "#ffffff"
        }
        """.utf8)

        let settings = try JSONDecoder().decode(HarnessSettings.self, from: data)

        XCTAssertEqual(settings.customBackgroundHex, "#000000")
        XCTAssertEqual(settings.customForegroundHex, "#ffffff")
    }

    func testNotificationSoundRoundTripsAndDefaultsTrueWhenMissing() throws {
        // Older settings files predate the chime toggle: decoding must default it on
        // (so existing users keep an audible ping), not crash or default off.
        let legacy = Data("""
        { "fontSize": 14, "customBackgroundHex": "#000000" }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertTrue(migrated.notificationSoundEnabled)

        // And an explicit value survives a save/load round-trip.
        var settings = HarnessSettings()
        settings.notificationSoundEnabled = false
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: encoded)
        XCTAssertFalse(decoded.notificationSoundEnabled)
    }

    func testImportedDefaultsKeepFullColorSet() {
        let imported = ImportedTerminalConfig(
            backgroundHex: "#000000",
            foregroundHex: "#ffffff",
            cursorColorHex: "#cccccc",
            selectionBackgroundHex: "#123456",
            selectionForegroundHex: "#abcdef",
            boldColorHex: "#eeeeee",
            cursorTextHex: "#000000",
            minimumContrast: 1.5,
            paletteHex: ["#111111"] + Array(repeating: nil, count: 15),
            cursorStyle: "bar",
            cursorBlink: false,
            copyOnSelect: true
        )

        let settings = HarnessSettings.makeDefaults(imported: imported)

        XCTAssertEqual(settings.customBackgroundHex, "#000000")
        XCTAssertEqual(settings.customForegroundHex, "#ffffff")
        XCTAssertEqual(settings.customCursorHex, "#cccccc")
        // Full terminal parity: selection/bold/cursor-text/palette are kept.
        XCTAssertEqual(settings.selectionBackgroundHex, "#123456")
        XCTAssertEqual(settings.selectionForegroundHex, "#abcdef")
        XCTAssertEqual(settings.boldColorHex, "#eeeeee")
        XCTAssertEqual(settings.cursorTextHex, "#000000")
        XCTAssertEqual(settings.paletteHex[0], "#111111")
        XCTAssertEqual(settings.paletteHex.count, 16)
        XCTAssertEqual(settings.cursorStyle, "bar")
        XCTAssertFalse(settings.cursorBlink)
        XCTAssertTrue(settings.copyOnSelect)
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

    func testResetToImportedConfigResetsVisualFieldsToDefaultsAndPreservesShell() {
        var s = HarnessSettings()
        s.defaultShell = "/opt/homebrew/bin/fish"
        s.defaultCWD = "/tmp/work"
        s.backgroundOpacity = 0.42
        s.backgroundBlur = 20
        s.fontSize = 99
        s.customBackgroundHex = "#123456"
        s.paletteHex[0] = "#abcdef"

        s.resetToImportedConfig()

        // Reset lands on the first-run defaults (the memberwise init), not a separate set.
        let defaults = HarnessSettings()
        XCTAssertEqual(s.backgroundOpacity, defaults.backgroundOpacity)
        XCTAssertEqual(s.backgroundBlur, defaults.backgroundBlur)
        XCTAssertEqual(s.fontSize, defaults.fontSize)
        XCTAssertNil(s.customBackgroundHex)
        XCTAssertNil(s.paletteHex[0])
        // Behavior fields are untouched.
        XCTAssertEqual(s.defaultShell, "/opt/homebrew/bin/fish")
        XCTAssertEqual(s.defaultCWD, "/tmp/work")
    }

    func testFontSizeIsHarnessOwnedNotImported() {
        // A source terminal's font *size* must not carry over (only the face does), so the
        // Harness default size wins even when the imported config specifies one.
        let imported = ImportedTerminalConfig(
            fontFamily: "JetBrainsMono Nerd Font",
            fontSize: 17,
            backgroundOpacity: 0.85
        )
        let settings = HarnessSettings.makeDefaults(imported: imported)
        XCTAssertEqual(settings.fontFamily, "JetBrainsMono Nerd Font") // face imported
        XCTAssertEqual(settings.fontSize, HarnessSettings().fontSize)  // size is the Harness default
        XCTAssertEqual(settings.backgroundOpacity, 0.85)              // other fields still import
    }
}
