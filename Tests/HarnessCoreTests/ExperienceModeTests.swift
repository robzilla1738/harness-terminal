import XCTest
@testable import HarnessCore

final class ExperienceModeTests: XCTestCase {
    func testFreshInstallDefaultsToPlain() {
        // The memberwise init is the fresh-install path (via makeDefaults). New users get the
        // simplest experience — a fast native terminal.
        XCTAssertEqual(HarnessSettings().experienceMode, .plain)
        XCTAssertNil(HarnessSettings().tmuxControlsEnabled)
    }

    func testLegacyFileWithoutModeMigratesToTmux() throws {
        // A settings file written before modes existed belongs to a user who already had the
        // prefix + status line. Decoding must default the absent key to `.tmux` so upgrading
        // never strips features — NOT to the fresh-install `.plain`.
        let legacy = #"{"fontSize":16,"fontFamily":"Menlo","defaultShell":"/bin/zsh","defaultCWD":"/Users/x","transparentTitlebar":true,"sidebarVisible":true,"backgroundOpacity":0.6,"backgroundBlur":16,"windowPaddingX":14,"windowPaddingY":14,"prefixKey":"ctrl-a","scrollbackLines":10000,"cursorStyle":"block","cursorBlink":true,"copyOnSelect":true,"paletteHex":[null,null,null,null,null,null,null,null,null,null,null,null,null,null,null,null],"agentColorOverrides":{},"systemNotificationsEnabled":true,"notificationSoundEnabled":true,"vividColors":true,"linearBlending":false,"applyThemeToTerminalOutput":false,"ligatures":true,"showStatusLine":true}"#
        let settings = try JSONDecoder().decode(HarnessSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.experienceMode, .tmux)
        XCTAssertTrue(settings.showsTmuxChrome)
    }

    func testShowsTmuxChromeDerivesFromMode() {
        XCTAssertFalse(HarnessSettings(experienceMode: .plain).showsTmuxChrome)
        XCTAssertFalse(HarnessSettings(experienceMode: .persistent).showsTmuxChrome)
        XCTAssertTrue(HarnessSettings(experienceMode: .tmux).showsTmuxChrome)
        XCTAssertFalse(HarnessSettings(experienceMode: .agent).showsTmuxChrome)
    }

    func testTmuxControlsOverrideWinsOverMode() {
        // Persistent/Agent users can opt into the prefix + status line without leaving their mode.
        XCTAssertTrue(HarnessSettings(experienceMode: .agent, tmuxControlsEnabled: true).showsTmuxChrome)
        // …and a Tmux user can turn the chrome off without switching modes.
        XCTAssertFalse(HarnessSettings(experienceMode: .tmux, tmuxControlsEnabled: false).showsTmuxChrome)
    }

    func testEffectivePrefixKey() {
        // Non-tmux chrome → no prefix at all, regardless of the stored key.
        XCTAssertNil(HarnessSettings(prefixKey: "ctrl-a", experienceMode: .plain).effectivePrefixKey)
        // Tmux chrome → honor the stored key.
        XCTAssertEqual(HarnessSettings(prefixKey: "ctrl-b", experienceMode: .tmux).effectivePrefixKey, "ctrl-b")
        // Tmux chrome but a blanked key → disabled (fixes the old fall-back-to-Ctrl-A bug).
        XCTAssertNil(HarnessSettings(prefixKey: "", experienceMode: .tmux).effectivePrefixKey)
        XCTAssertNil(HarnessSettings(prefixKey: "   ", experienceMode: .tmux).effectivePrefixKey)
    }

    func testPersistenceDefaultsByMode() {
        XCTAssertFalse(ExperienceMode.plain.persistsSessionsByDefault)
        XCTAssertTrue(ExperienceMode.persistent.persistsSessionsByDefault)
        XCTAssertTrue(ExperienceMode.tmux.persistsSessionsByDefault)
        XCTAssertTrue(ExperienceMode.agent.persistsSessionsByDefault)
    }

    func testModeSurvivesEncodeDecodeRoundTrip() throws {
        var settings = HarnessSettings(experienceMode: .agent, tmuxControlsEnabled: true)
        settings.prefixKey = "ctrl-b"
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: data)
        XCTAssertEqual(decoded.experienceMode, .agent)
        XCTAssertEqual(decoded.tmuxControlsEnabled, true)
    }

    func testResetToImportedConfigPreservesMode() {
        // "Reset to defaults" changes appearance, not behavior — the experience must stick.
        var settings = HarnessSettings(experienceMode: .tmux)
        settings.resetToImportedConfig(imported: nil)
        XCTAssertEqual(settings.experienceMode, .tmux)
    }
}
