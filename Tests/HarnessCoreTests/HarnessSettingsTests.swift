import XCTest
@testable import HarnessCore

final class HarnessSettingsTests: XCTestCase {
    private let colorMigrationKey = "HarnessColorFidelityMigrationV1"

    // MARK: - Decoder guard (roadmap PR-11)

    // The 60+ -property `init(from:)` is hand-written — every field needs its own
    // `decodeIfPresent` line. A field that encodes but is never decoded (a forgotten line) would
    // silently revert to the fallback on every load. The guard below sets a non-default value on
    // a field of every stored type and asserts each survives a coding round-trip — a missing decode
    // line reverts that field and trips its assertion.
    //
    // Why per-field (not whole-struct `==`): the absent-key fallback is intentionally
    // environment-derived (`makeDefaults(imported:)` seeds from any imported terminal config), and
    // hex values are normalized to uppercase on decode — so `decode(encode(x)) == x` is not a
    // machine-independent invariant. Asserting the explicitly-set fields (present in the JSON, hex
    // uppercased) is immune to both and still proves each decode line carries its value.
    /// `scrollMultiplier` is documented as "clamped to a sane range on read" — the `init(from:)`
    /// decoder must apply `clampedScrollMultiplier` (like `minimumContrast` does), so a hand-edited
    /// settings.json with an out-of-range value can't reach the renderer and freeze/invert scrolling.
    func testScrollMultiplierIsClampedOnDecode() throws {
        func decoded(_ raw: Double) throws -> Double {
            var s = HarnessSettings()
            s.scrollMultiplier = raw
            let data = try JSONEncoder().encode(s)
            return try JSONDecoder().decode(HarnessSettings.self, from: data).scrollMultiplier
        }
        XCTAssertEqual(try decoded(999), 10, accuracy: 1e-9, "a huge hand-edited value clamps to the max on read")
        XCTAssertEqual(try decoded(-5), 0.1, accuracy: 1e-9, "a negative value clamps to the min")
        XCTAssertEqual(try decoded(0), 0.1, accuracy: 1e-9, "zero clamps to the min")
        XCTAssertEqual(try decoded(2.5), 2.5, accuracy: 1e-9, "an in-range value is preserved")
    }

    func testEveryFieldTypeSurvivesACodingRoundTrip() throws {
        var s = HarnessSettings()
        s.fontSize = 19.5
        s.fontFamily = "Berkeley Mono"
        s.defaultShell = "/usr/local/bin/fish"
        s.defaultCWD = "/tmp/work"
        s.transparentTitlebar = false
        s.sidebarVisible = false
        s.restoreWindowSize = true
        s.backgroundOpacity = 0.42
        s.backgroundBlur = 7
        s.windowPaddingX = 9
        s.windowPaddingY = 11
        s.customBackgroundHex = "#101010"
        s.customForegroundHex = "#E0E0E0"
        s.customCursorHex = "#FF8800"
        s.prefixKey = "ctrl-b"
        s.scrollbackLines = 99_999
        s.cursorStyle = "block"
        s.cursorBlink = false
        s.copyOnSelect = false
        s.dividerHex = "#222222"
        s.statusLineHex = "#ABCDEF"
        s.windowBorderHex = "#333333"
        s.windowBorderOpacity = 0.9
        s.minimumContrast = 4.5
        s.vividColors = true
        s.linearBlending = true
        s.applyThemeToTerminalOutput = true
        s.ligatures = false
        s.boldIsBright = false
        s.pasteProtection = false
        s.secureKeyboardEntry = true
        s.commandFinishedThresholdSeconds = 30
        s.paletteHex[0] = "#000001"
        s.paletteHex[15] = "#FFFFFE"
        s.agentColorOverrides["claude-code"] = "#7C3AED"
        s.setEventEnabled(.bell, false)
        s.setEventEnabled(.commandFinished, true)
        s.colorRendering = .vivid
        s.experienceMode = .full
        s.notchVisibilityMode = .on
        s.resizeOverlay = .always
        s.bellMode = .both
        s.scrollMultiplier = 2.5
        s.mouseHideWhileTyping = true
        s.quickTerminalEnabled = true
        s.quickTerminalHotkey = "ctrl-opt-k"

        let d = try JSONDecoder().decode(HarnessSettings.self, from: JSONEncoder().encode(s))

        XCTAssertEqual(d.fontSize, 19.5)
        XCTAssertEqual(d.fontFamily, "Berkeley Mono")
        XCTAssertEqual(d.defaultShell, "/usr/local/bin/fish")
        XCTAssertEqual(d.defaultCWD, "/tmp/work")
        XCTAssertEqual(d.transparentTitlebar, false)
        XCTAssertEqual(d.sidebarVisible, false)
        XCTAssertEqual(d.restoreWindowSize, true)
        XCTAssertEqual(d.backgroundOpacity, 0.42)
        XCTAssertEqual(d.backgroundBlur, 7)
        XCTAssertEqual(d.windowPaddingX, 9)
        XCTAssertEqual(d.windowPaddingY, 11)
        XCTAssertEqual(d.customBackgroundHex, "#101010")
        XCTAssertEqual(d.customForegroundHex, "#E0E0E0")
        XCTAssertEqual(d.customCursorHex, "#FF8800")
        XCTAssertEqual(d.prefixKey, "ctrl-b")
        XCTAssertEqual(d.scrollbackLines, 99_999)
        XCTAssertEqual(d.cursorStyle, "block")
        XCTAssertEqual(d.cursorBlink, false)
        XCTAssertEqual(d.copyOnSelect, false)
        XCTAssertEqual(d.dividerHex, "#222222")
        XCTAssertEqual(d.statusLineHex, "#ABCDEF")
        XCTAssertEqual(d.windowBorderHex, "#333333")
        XCTAssertEqual(d.windowBorderOpacity, 0.9)
        XCTAssertEqual(d.minimumContrast, 4.5)
        XCTAssertEqual(d.vividColors, true)
        XCTAssertEqual(d.linearBlending, true)
        XCTAssertEqual(d.applyThemeToTerminalOutput, true)
        XCTAssertEqual(d.ligatures, false)
        XCTAssertEqual(d.boldIsBright, false)
        XCTAssertEqual(d.pasteProtection, false)
        XCTAssertEqual(d.secureKeyboardEntry, true)
        XCTAssertEqual(d.commandFinishedThresholdSeconds, 30)
        XCTAssertEqual(d.paletteHex[0], "#000001")
        XCTAssertEqual(d.paletteHex[15], "#FFFFFE")
        XCTAssertEqual(d.agentColorOverrides["claude-code"], "#7C3AED")
        XCTAssertFalse(d.isEventEnabled(.bell))
        XCTAssertTrue(d.isEventEnabled(.commandFinished))
        XCTAssertEqual(d.colorRendering, .vivid)
        XCTAssertEqual(d.experienceMode, .full)
        XCTAssertEqual(d.notchVisibilityMode, .on)
        XCTAssertEqual(d.resizeOverlay, .always)
        XCTAssertEqual(d.bellMode, .both)
        XCTAssertEqual(d.scrollMultiplier, 2.5)
        XCTAssertEqual(d.mouseHideWhileTyping, true)
        XCTAssertEqual(d.quickTerminalEnabled, true)
        XCTAssertEqual(d.quickTerminalHotkey, "ctrl-opt-k")
    }

    func testScrollMultiplierAndMouseHideDefaults() {
        let s = HarnessSettings()
        XCTAssertEqual(s.scrollMultiplier, 1, "native scroll speed by default")
        XCTAssertFalse(s.mouseHideWhileTyping, "off by default (matching Ghostty)")
    }

    func testScrollMultiplierClampsToSaneRange() {
        XCTAssertEqual(HarnessSettings.clampedScrollMultiplier(0), 0.1, "0 would freeze scrolling")
        XCTAssertEqual(HarnessSettings.clampedScrollMultiplier(-3), 0.1)
        XCTAssertEqual(HarnessSettings.clampedScrollMultiplier(999), 10, "cap pages-per-notch")
        XCTAssertEqual(HarnessSettings.clampedScrollMultiplier(2.5), 2.5, "in-range passes through")
    }

    /// An empty object must decode without throwing — guards against a field decoded with the
    /// throwing `decode` (a required key) instead of `decodeIfPresent`, which would break every
    /// older/partial settings file.
    func testEmptyObjectDecodesWithoutThrowing() {
        XCTAssertNoThrow(try JSONDecoder().decode(HarnessSettings.self, from: Data("{}".utf8)))
    }

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

    func testVividColorsDefaultsToAccurateSRGBWhenMissing() throws {
        XCTAssertFalse(HarnessSettings().vividColors)
        XCTAssertEqual(HarnessSettings().colorRendering, .accurate)
        XCTAssertFalse(HarnessSettings.makeDefaults(imported: nil).vividColors)
        XCTAssertEqual(HarnessSettings.makeDefaults(imported: nil).colorRendering, .accurate)

        let legacy = Data("""
        { "fontSize": 14, "customBackgroundHex": "#000000" }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertFalse(migrated.vividColors)
        XCTAssertEqual(migrated.colorRendering, .accurate)
    }

    func testFreshSettingsUseSlimBarCursorByDefault() {
        XCTAssertEqual(HarnessSettings().cursorStyle, "bar")
        XCTAssertEqual(HarnessSettings.makeDefaults(imported: nil).cursorStyle, "bar")
    }

    // MARK: - Per-event notification gating

    func testNotificationEventDefaultsMatchPriorBehavior() {
        let settings = HarnessSettings()
        XCTAssertTrue(settings.isEventEnabled(.agentWaiting))
        XCTAssertTrue(settings.isEventEnabled(.agentFinished))
        XCTAssertTrue(settings.isEventEnabled(.bell))
        // Command-finished stays opt-in, as the standalone toggle was.
        XCTAssertFalse(settings.isEventEnabled(.commandFinished))
    }

    func testSetEventEnabledRoundTripsThroughCoding() throws {
        var settings = HarnessSettings()
        settings.setEventEnabled(.bell, false)
        settings.setEventEnabled(.commandFinished, true)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: data)

        XCTAssertFalse(decoded.isEventEnabled(.bell))
        XCTAssertTrue(decoded.isEventEnabled(.commandFinished))
        // Untouched events still resolve to their defaults.
        XCTAssertTrue(decoded.isEventEnabled(.agentWaiting))
    }

    func testLegacyCommandFinishedNotificationsMigratesIntoEventMap() throws {
        let legacy = Data("""
        { "fontSize": 14, "commandFinishedNotifications": true }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertTrue(migrated.isEventEnabled(.commandFinished))
        // Other events keep their defaults through the migration.
        XCTAssertTrue(migrated.isEventEnabled(.agentWaiting))
    }

    func testExplicitEventMapWinsOverLegacyCommandFinishedFlag() throws {
        // A user who has already moved to the new map shouldn't have a stale legacy flag override it.
        let blob = Data("""
        { "fontSize": 14, "commandFinishedNotifications": true, "notificationEvents": { "commandFinished": false } }
        """.utf8)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: blob)
        XCTAssertFalse(decoded.isEventEnabled(.commandFinished))
    }

    func testSettingsWithNoNotificationKeysDecodeToDefaults() throws {
        let blob = Data(#"{ "fontSize": 14 }"#.utf8)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: blob)
        XCTAssertTrue(decoded.isEventEnabled(.agentFinished))
        XCTAssertFalse(decoded.isEventEnabled(.commandFinished))
    }

    func testVividColorsLoadMigrationPreservesExplicitChoice() throws {
        try withTemporaryHarnessHome { root in
            try HarnessPaths.ensureDirectories()
            try Data("""
            { "fontSize": 14, "vividColors": true }
            """.utf8).write(to: root.appendingPathComponent("settings.json"))

            try withResetColorMigration {
                let settings = HarnessSettings.load()
                XCTAssertTrue(settings.vividColors)
                XCTAssertEqual(settings.colorRendering, .vivid)
            }
        }
    }

    func testVividColorsLoadMigrationDefaultsMissingKeyToSRGB() throws {
        try withTemporaryHarnessHome { root in
            try HarnessPaths.ensureDirectories()
            try Data("""
            { "fontSize": 14 }
            """.utf8).write(to: root.appendingPathComponent("settings.json"))

            try withResetColorMigration {
                let settings = HarnessSettings.load()
                XCTAssertFalse(settings.vividColors)
                XCTAssertEqual(settings.colorRendering, .accurate)
            }
        }
    }

    func testColorRenderingLoadMigrationPreservesExplicitNewChoice() throws {
        try withTemporaryHarnessHome { root in
            try HarnessPaths.ensureDirectories()
            try Data("""
            { "fontSize": 14, "colorRendering": "vivid" }
            """.utf8).write(to: root.appendingPathComponent("settings.json"))

            try withResetColorMigration {
                let settings = HarnessSettings.load()
                XCTAssertEqual(settings.colorRendering, .vivid)
                XCTAssertTrue(settings.vividColors)
            }
        }
    }

    func testLegacyVividColorsMapsToVividRenderingMode() throws {
        let legacy = Data("""
        { "fontSize": 14, "vividColors": true }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)

        XCTAssertTrue(migrated.vividColors)
        XCTAssertEqual(migrated.colorRendering, .vivid)
    }

    func testExplicitRenderingModesRoundTripWithLegacyAliases() throws {
        var settings = HarnessSettings(colorRendering: .vivid, textRendering: .soft)
        settings.colorGamut = .displayP3

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: encoded)

        XCTAssertEqual(decoded.colorRendering, .vivid)
        XCTAssertEqual(decoded.colorGamut, .displayP3)
        XCTAssertEqual(decoded.textRendering, .soft)
        XCTAssertTrue(decoded.vividColors)
        XCTAssertFalse(decoded.linearBlending)
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

    func testSecureKeyboardEntryDefaultsOffAndRoundTrips() throws {
        // Opt-in security feature: a fresh install and any settings file predating it must decode
        // to off (never silently force the global secure-input lock on for existing users).
        XCTAssertFalse(HarnessSettings().secureKeyboardEntry)
        let legacy = Data("""
        { "fontSize": 14, "customBackgroundHex": "#000000" }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertFalse(migrated.secureKeyboardEntry)

        // An explicit on value survives a save/load round-trip.
        var settings = HarnessSettings()
        settings.secureKeyboardEntry = true
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: try JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.secureKeyboardEntry)
    }

    func testNotchSettingsDefaultAndLegacyDecode() throws {
        XCTAssertEqual(HarnessSettings().notchVisibilityMode, .automatic)
        XCTAssertTrue(HarnessSettings().notchOpenOnHover)

        let legacy = Data("""
        { "fontSize": 14, "customBackgroundHex": "#000000" }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertEqual(migrated.notchVisibilityMode, .automatic)
        XCTAssertTrue(migrated.notchOpenOnHover)
    }

    func testNotchSettingsRoundTripAndAutomaticResolution() throws {
        var settings = HarnessSettings()
        settings.notchVisibilityMode = .off
        settings.notchOpenOnHover = false

        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: try JSONEncoder().encode(settings))

        XCTAssertEqual(decoded.notchVisibilityMode, .off)
        XCTAssertFalse(decoded.notchOpenOnHover)

        XCTAssertFalse(NotchVisibilityMode.automatic.isEnabled(for: .plain))
        XCTAssertFalse(NotchVisibilityMode.automatic.isEnabled(for: .persistent))
        XCTAssertFalse(NotchVisibilityMode.automatic.isEnabled(for: .full))
        XCTAssertTrue(NotchVisibilityMode.automatic.isEnabled(for: .agent))
        XCTAssertTrue(NotchVisibilityMode.on.isEnabled(for: .plain))
        XCTAssertFalse(NotchVisibilityMode.off.isEnabled(for: .agent))
    }

    func testOffMainParserFramePipelineDefaultsOnAndRoundTrips() throws {
        // Now the production default: parse + frame build run off the main thread.
        XCTAssertTrue(HarnessSettings().offMainParserFramePipeline)

        // A legacy settings.json with no key gets the fast path on upgrade.
        let legacy = Data("""
        { "fontSize": 14, "customBackgroundHex": "#000000" }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertTrue(migrated.offMainParserFramePipeline, "absent key defaults to on")

        // An explicitly stored `false` is honored as an opt-out.
        let optedOut = Data("""
        { "fontSize": 14, "offMainParserFramePipeline": false }
        """.utf8)
        let decodedOptOut = try JSONDecoder().decode(HarnessSettings.self, from: optedOut)
        XCTAssertFalse(decodedOptOut.offMainParserFramePipeline, "explicit false is preserved")

        var settings = HarnessSettings()
        settings.offMainParserFramePipeline = false
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: encoded)
        XCTAssertFalse(decoded.offMainParserFramePipeline)
    }

    func testLiveResizeReflowDefaultsOnAndRoundTrips() throws {
        // Real-time (Ghostty-style) resize is the production default.
        XCTAssertTrue(HarnessSettings().liveResizeReflow)

        // A legacy settings.json with no key gets real-time resize on upgrade.
        let legacy = Data("""
        { "fontSize": 14, "customBackgroundHex": "#000000" }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertTrue(migrated.liveResizeReflow, "absent key defaults to on")

        // An explicitly stored `false` is honored as an opt-out to defer-to-release.
        let optedOut = Data("""
        { "fontSize": 14, "liveResizeReflow": false }
        """.utf8)
        let decodedOptOut = try JSONDecoder().decode(HarnessSettings.self, from: optedOut)
        XCTAssertFalse(decodedOptOut.liveResizeReflow, "explicit false is preserved")

        var settings = HarnessSettings()
        settings.liveResizeReflow = false
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: encoded)
        XCTAssertFalse(decoded.liveResizeReflow)
    }

    func testRestoreWindowSizeDefaultsOffAndRoundTrips() throws {
        // New option: opt-in window frame persistence. Default off so existing users
        // keep the centered default-size launch.
        XCTAssertFalse(HarnessSettings().restoreWindowSize)

        // A settings file predating the key decodes to the off default.
        let legacy = Data("""
        { "fontSize": 14, "customBackgroundHex": "#000000" }
        """.utf8)
        let migrated = try JSONDecoder().decode(HarnessSettings.self, from: legacy)
        XCTAssertFalse(migrated.restoreWindowSize, "absent key defaults to off")

        // An explicit value survives a save/load round-trip.
        var settings = HarnessSettings()
        settings.restoreWindowSize = true
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: encoded)
        XCTAssertTrue(decoded.restoreWindowSize)
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

    func testClampedFontSizeStaysInZoomRange() {
        // 8–32 matches the Cmd+/- zoom policy; out-of-range values are footguns
        // (huge → glyph-atlas overflow → invisible text; tiny → multi-hundred-MB grid alloc).
        XCTAssertEqual(HarnessSettings.clampedFontSize(0), 8, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedFontSize(1), 8, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedFontSize(8), 8, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedFontSize(16), 16, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedFontSize(32), 32, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedFontSize(999), 32, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedFontSize(-5), 8, accuracy: 0.001)
    }

    func testFontSizeIsClampedAtEveryPersistenceBoundary() throws {
        // init clamps.
        XCTAssertEqual(HarnessSettings(fontSize: 999).fontSize, 32, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings(fontSize: 1).fontSize, 8, accuracy: 0.001)

        // init(from:) clamps a decoded out-of-range value.
        let huge = try JSONDecoder().decode(HarnessSettings.self, from: Data(#"{ "fontSize": 999 }"#.utf8))
        XCTAssertEqual(huge.fontSize, 32, accuracy: 0.001)
        let tiny = try JSONDecoder().decode(HarnessSettings.self, from: Data(#"{ "fontSize": 1 }"#.utf8))
        XCTAssertEqual(tiny.fontSize, 8, accuracy: 0.001)
        let negative = try JSONDecoder().decode(HarnessSettings.self, from: Data(#"{ "fontSize": -5 }"#.utf8))
        XCTAssertEqual(negative.fontSize, 8, accuracy: 0.001)
    }

    func testLoadClampsRunawayFontSizeAndPaddingAndRewritesOnce() throws {
        try withTemporaryHarnessHome { root in
            try HarnessPaths.ensureDirectories()
            let url = root.appendingPathComponent("settings.json")
            // A hand-edited file with a runaway font size and negative padding. load() must clamp
            // and persist the recovered state (the didMutate rewrite path), like the opacity floor.
            try Data(#"{ "fontSize": 999, "windowPaddingX": -10, "windowPaddingY": -3 }"#.utf8).write(to: url)

            let settings = HarnessSettings.load()
            XCTAssertEqual(settings.fontSize, 32, accuracy: 0.001)
            XCTAssertEqual(settings.windowPaddingX, 0, accuracy: 0.001)
            XCTAssertEqual(settings.windowPaddingY, 0, accuracy: 0.001)

            // The migrated, clamped state is persisted back to disk.
            let reloaded = try JSONDecoder().decode(HarnessSettings.self, from: try Data(contentsOf: url))
            XCTAssertEqual(reloaded.fontSize, 32, accuracy: 0.001)
            XCTAssertEqual(reloaded.windowPaddingX, 0, accuracy: 0.001)
        }
    }

    func testClampedPaddingNeverNegative() {
        XCTAssertEqual(HarnessSettings.clampedPadding(-10), 0, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedPadding(0), 0, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings.clampedPadding(14), 14, accuracy: 0.001)
        XCTAssertEqual(HarnessSettings(windowPaddingX: -5, windowPaddingY: -1).windowPaddingX, 0, accuracy: 0.001)
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

    func testCorruptSettingsAreBackedUpNotOverwritten() throws {
        try withTemporaryHarnessHome { root in
            try HarnessPaths.ensureDirectories()
            let url = root.appendingPathComponent("settings.json")
            // A garbage file that exists but can't be decoded: load() must preserve it as `.corrupt`
            // and return in-memory defaults WITHOUT rewriting the original (which would discard the
            // user's real settings the moment a partial write or disk glitch produced bad JSON).
            try Data("{ this is not valid json ".utf8).write(to: url)

            let settings = HarnessSettings.load()
            XCTAssertEqual(settings.fontSize, HarnessSettings.makeDefaults(imported: nil).fontSize)

            let backup = url.appendingPathExtension("corrupt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the unreadable file is renamed .corrupt")
            XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ this is not valid json ")
            // The original path must NOT have been recreated with defaults (no silent overwrite).
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "load() must not rewrite the original over the corrupt file")
        }
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

    private func withTemporaryHarnessHome(_ body: (URL) throws -> Void) throws {
        let previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let root = URL(fileURLWithPath: "/tmp/harness-settings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("HARNESS_HOME", root.path, 1)
        defer {
            if let previousHome {
                setenv("HARNESS_HOME", previousHome, 1)
            } else {
                unsetenv("HARNESS_HOME")
            }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    private func withResetColorMigration(_ body: () throws -> Void) throws {
        let previousValue = UserDefaults.standard.object(forKey: colorMigrationKey)
        UserDefaults.standard.removeObject(forKey: colorMigrationKey)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: colorMigrationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: colorMigrationKey)
            }
        }
        try body()
    }

    // MARK: - Forward-compat decode (the FieldDecoder seam, PR-31)

    /// Unknown keys in a NEWER settings file must be ignored — a downgrade (or a file
    /// shared from a newer build) decodes cleanly instead of failing the whole load.
    func testUnknownKeysAreIgnoredOnDecode() throws {
        let futuristic = Data("""
        { "fontSize": 17, "someFieldFromTheFuture": { "nested": [1, 2, 3] }, "anotherUnknown": "x" }
        """.utf8)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: futuristic)
        XCTAssertEqual(decoded.fontSize, 17)
        let fallback = HarnessSettings.makeDefaults(imported: TerminalConfigImporter.load())
        XCTAssertEqual(decoded.fontFamily, fallback.fontFamily, "absent keys fall back to defaults")
    }

    /// Every key absent → every field equals the fallback instance the decoder funnels
    /// through. That fallback is `makeDefaults(imported:)`, NOT `HarnessSettings()`: on a
    /// machine with an importable terminal config (Ghostty/iTerm2) the defaults are
    /// import-aware (shell, opacity, font), so comparing against the plain initializer
    /// only passes on machines with nothing to import (like CI). Spot-checks a
    /// representative spread of field types.
    func testMissingKeysDecodeToDefaultInstanceValues() throws {
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: Data("{}".utf8))
        let defaults = HarnessSettings.makeDefaults(imported: TerminalConfigImporter.load())
        XCTAssertEqual(decoded.defaultShell, defaults.defaultShell)
        XCTAssertEqual(decoded.backgroundOpacity, defaults.backgroundOpacity)
        XCTAssertEqual(decoded.scrollbackLines, defaults.scrollbackLines)
        XCTAssertEqual(decoded.bellMode, defaults.bellMode)
        XCTAssertEqual(decoded.quickTerminalHotkey, defaults.quickTerminalHotkey)
        XCTAssertEqual(decoded.agentColorOverrides, defaults.agentColorOverrides)
        XCTAssertEqual(decoded.boldIsBright, defaults.boldIsBright)
        XCTAssertEqual(decoded.resizeOverlayPosition, defaults.resizeOverlayPosition)
    }

    func testWindowInheritCWDDefaultsOnAndDecodesExplicitOff() throws {
        XCTAssertTrue(HarnessSettings().windowInheritCWD, "inherit is the shipped behavior — default on")
        let legacy = try JSONDecoder().decode(HarnessSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(legacy.windowInheritCWD, "older settings files keep inheriting")
        let off = try JSONDecoder().decode(
            HarnessSettings.self, from: Data(#"{ "windowInheritCWD": false }"#.utf8))
        XCTAssertFalse(off.windowInheritCWD)
    }
}
