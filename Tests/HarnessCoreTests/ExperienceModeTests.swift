import XCTest
@testable import HarnessCore

final class ExperienceModeTests: XCTestCase {
    func testFreshInstallDefaultsToPlain() {
        // The memberwise init is the fresh-install path (via makeDefaults). New users get the
        // simplest experience — a fast native terminal.
        XCTAssertEqual(HarnessSettings().experienceMode, .plain)
        XCTAssertNil(HarnessSettings().harnessControlsEnabled)
    }

    func testLegacyFileWithoutModeMigratesToFull() throws {
        // A settings file written before modes existed belongs to a user who already had the
        // prefix + status line. Decoding must default the absent key to `.full` so upgrading
        // never strips features — NOT to the fresh-install `.plain`.
        let legacy = #"{"fontSize":16,"fontFamily":"Menlo","defaultShell":"/bin/zsh","defaultCWD":"/Users/x","transparentTitlebar":true,"sidebarVisible":true,"backgroundOpacity":0.6,"backgroundBlur":16,"windowPaddingX":14,"windowPaddingY":14,"prefixKey":"ctrl-a","scrollbackLines":10000,"cursorStyle":"block","cursorBlink":true,"copyOnSelect":true,"paletteHex":[null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null],"agentColorOverrides":{},"systemNotificationsEnabled":true,"notificationSoundEnabled":true,"vividColors":true,"linearBlending":false,"applyThemeToTerminalOutput":false,"ligatures":true,"showStatusLine":true}"#
        let settings = try JSONDecoder().decode(HarnessSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.experienceMode, .full)
        XCTAssertTrue(settings.showsHarnessControls)
    }

    func testShowsHarnessControlsDerivesFromMode() {
        XCTAssertFalse(HarnessSettings(experienceMode: .plain).showsHarnessControls)
        XCTAssertFalse(HarnessSettings(experienceMode: .persistent).showsHarnessControls)
        XCTAssertTrue(HarnessSettings(experienceMode: .full).showsHarnessControls)
        XCTAssertFalse(HarnessSettings(experienceMode: .agent).showsHarnessControls)
    }

    func testHarnessControlsOverrideWinsOverMode() {
        // Persistent/Agent users can opt into the prefix + status line without leaving their mode.
        XCTAssertTrue(HarnessSettings(experienceMode: .agent, harnessControlsEnabled: true).showsHarnessControls)
        // …and a Full Terminal user can turn the controls off without switching modes.
        XCTAssertFalse(HarnessSettings(experienceMode: .full, harnessControlsEnabled: false).showsHarnessControls)
    }

    func testEffectivePrefixKey() {
        // Harness controls hidden → no prefix at all, regardless of the stored key.
        XCTAssertNil(HarnessSettings(prefixKey: "ctrl-a", experienceMode: .plain).effectivePrefixKey)
        // Harness controls visible → honor the stored key.
        XCTAssertEqual(HarnessSettings(prefixKey: "ctrl-b", experienceMode: .full).effectivePrefixKey, "ctrl-b")
        // Harness controls visible but a blanked key → disabled (fixes the old fall-back-to-Ctrl-A bug).
        XCTAssertNil(HarnessSettings(prefixKey: "", experienceMode: .full).effectivePrefixKey)
        XCTAssertNil(HarnessSettings(prefixKey: "   ", experienceMode: .full).effectivePrefixKey)
    }

    func testPersistenceDefaultsByMode() {
        XCTAssertFalse(ExperienceMode.plain.persistsSessionsByDefault)
        XCTAssertTrue(ExperienceMode.persistent.persistsSessionsByDefault)
        XCTAssertTrue(ExperienceMode.full.persistsSessionsByDefault)
        XCTAssertTrue(ExperienceMode.agent.persistsSessionsByDefault)
    }

    func testModeSurvivesEncodeDecodeRoundTrip() throws {
        var settings = HarnessSettings(experienceMode: .agent, harnessControlsEnabled: true)
        settings.prefixKey = "ctrl-b"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: data)
        XCTAssertEqual(decoded.experienceMode, .agent)
        XCTAssertEqual(decoded.harnessControlsEnabled, true)
    }

    func testLegacyTmuxControlsKeyDecodesIntoHarnessControls() throws {
        let legacy = #"{"experienceMode":"agent","tmuxControlsEnabled":true}"#
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.experienceMode, .agent)
        XCTAssertEqual(decoded.harnessControlsEnabled, true)
        XCTAssertTrue(decoded.showsHarnessControls)
    }

    func testResetToImportedConfigPreservesMode() {
        // "Reset to defaults" changes appearance, not behavior — the experience must stick.
        var settings = HarnessSettings(experienceMode: .full)
        settings.resetToImportedConfig(imported: nil)
        XCTAssertEqual(settings.experienceMode, .full)
    }
}
