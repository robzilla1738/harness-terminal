import XCTest
@testable import HarnessCore

final class SettingsViewControllerFollowSystemThemeTests: XCTestCase {
    func testFollowSystemShowsLightAndDarkThemeSelectors() throws {
        let source = try settingsViewControllerSource()

        XCTAssertTrue(source.contains("private let systemLightThemePopup = HarnessSelect(frame: .zero)"))
        XCTAssertTrue(source.contains("private let systemDarkThemePopup = HarnessSelect(frame: .zero)"))
        XCTAssertTrue(source.contains("settingsRow(\"Light Theme\", systemLightThemePopup)"))
        XCTAssertTrue(source.contains("settingsRow(\"Dark Theme\", systemDarkThemePopup)"))
        XCTAssertTrue(source.contains("let followsSystem = selectedAppearanceMode == .macOSSystem"))
        XCTAssertTrue(source.contains("row.isHidden = !followsSystem"))
        XCTAssertTrue(source.contains("systemLightThemePopup.isEnabled = followsSystem"))
        XCTAssertTrue(source.contains("systemDarkThemePopup.isEnabled = followsSystem"))
    }

    func testSystemThemeSelectorsPersistWithoutMutatingThemeNameAndClearOverrides() throws {
        let source = try settingsViewControllerSource()

        XCTAssertTrue(source.contains("coordinator.settings.systemLightThemeName = theme"))
        XCTAssertTrue(source.contains("coordinator.settings.systemDarkThemeName = theme"))
        XCTAssertTrue(source.contains("coordinator.applySettingsToHosts()"))
        let lightHandler = try sourceBlock(named: "systemLightThemeDidChange", in: source)
        let darkHandler = try sourceBlock(named: "systemDarkThemeDidChange", in: source)
        XCTAssertFalse(lightHandler.contains("setTheme"))
        XCTAssertFalse(darkHandler.contains("setTheme"))
        XCTAssertTrue(lightHandler.contains("coordinator.settings.clearThemeColorOverrides()"))
        XCTAssertTrue(darkHandler.contains("coordinator.settings.clearThemeColorOverrides()"))

        let model = PersistedSystemThemeSelection(
            themeName: "Dracula",
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Harness Default"
        ).selecting(light: "GitHub Light", dark: "Tokyo Night")

        XCTAssertEqual(model.themeName, "Dracula")
        XCTAssertEqual(model.systemLightThemeName, "GitHub Light")
        XCTAssertEqual(model.systemDarkThemeName, "Tokyo Night")
    }

    func testThemeAndAppearanceTransitionsClearOverridesWithoutMutatingOtherThemeSelectors() throws {
        let settingsSource = try settingsViewControllerSource()
        let coordinatorSource = try sessionCoordinatorSource()

        let themeHandler = try sourceBlock(named: "themeDidChange", in: settingsSource)
        XCTAssertTrue(themeHandler.contains("SessionCoordinator.shared.setTheme(theme)"))

        let setTheme = try sourceBlock(named: "setTheme", in: coordinatorSource)
        XCTAssertTrue(setTheme.contains("settings.clearThemeColorOverrides()"))
        XCTAssertFalse(setTheme.contains("settings.systemLightThemeName ="))
        XCTAssertFalse(setTheme.contains("settings.systemDarkThemeName ="))

        let applySettingsLive = try sourceBlock(named: "applySettingsLive", in: settingsSource)
        XCTAssertTrue(applySettingsLive.contains("previousAppearanceMode != nextAppearanceMode"))
        XCTAssertTrue(applySettingsLive.contains("coordinator.settings.clearThemeColorOverrides()"))
        XCTAssertTrue(applySettingsLive.contains("paletteHexValues = HarnessSettings.normalizedPalette(coordinator.settings.paletteHex)"))
        XCTAssertFalse(applySettingsLive.contains("coordinator.settings.systemLightThemeName = selectedAppearanceMode"))
        XCTAssertFalse(applySettingsLive.contains("coordinator.settings.systemDarkThemeName = selectedAppearanceMode"))
    }

    func testClearThemeColorOverridesClearsExactResetFieldsAndPreservesNonResetFields() {
        var settings = HarnessSettings(
            fontSize: 21,
            fontFamily: "Menlo",
            defaultShell: "/opt/homebrew/bin/fish",
            defaultCWD: "/tmp/project",
            transparentTitlebar: false,
            sidebarVisible: false,
            backgroundOpacity: 0.42,
            backgroundBlur: 31,
            appearanceMode: .macOSSystem,
            systemLightThemeName: "GitHub Light",
            systemDarkThemeName: "Dracula",
            customBackgroundHex: "#111111",
            customForegroundHex: "#222222",
            customCursorHex: "#333333",
            importedConfigSignature: "signature",
            prefixKey: "ctrl-b",
            scrollbackLines: 12345,
            cursorStyle: "underline",
            cursorBlink: false,
            copyOnSelect: false,
            selectionBackgroundHex: "#444444",
            selectionForegroundHex: "#555555",
            boldColorHex: "#666666",
            cursorTextHex: "#777777",
            paletteHex: ["#000000"] + Array(repeating: nil, count: 15),
            agentColorOverrides: ["codex": "#123456"],
            dividerHex: "#888888",
            statusLineHex: "#999999",
            systemNotificationsEnabled: false,
            notificationSoundEnabled: false,
            colorRendering: .vivid,
            colorGamut: .displayP3,
            textRendering: .crisp,
            vividColors: true,
            linearBlending: true,
            applyThemeToTerminalOutput: true,
            ligatures: false,
            offMainParserFramePipeline: false,
            showPromptGutter: true,
            showStatusLine: false,
            experienceMode: .agent,
            harnessControlsEnabled: true
        )

        settings.clearThemeColorOverrides()

        XCTAssertNil(settings.customBackgroundHex)
        XCTAssertNil(settings.customForegroundHex)
        XCTAssertNil(settings.customCursorHex)
        XCTAssertNil(settings.selectionBackgroundHex)
        XCTAssertNil(settings.selectionForegroundHex)
        XCTAssertNil(settings.boldColorHex)
        XCTAssertNil(settings.cursorTextHex)
        XCTAssertNil(settings.dividerHex)
        XCTAssertNil(settings.statusLineHex)

        XCTAssertEqual(settings.fontSize, 21)
        XCTAssertEqual(settings.fontFamily, "Menlo")
        XCTAssertEqual(settings.defaultShell, "/opt/homebrew/bin/fish")
        XCTAssertEqual(settings.defaultCWD, "/tmp/project")
        XCTAssertFalse(settings.transparentTitlebar)
        XCTAssertFalse(settings.sidebarVisible)
        XCTAssertEqual(settings.backgroundOpacity, 0.42)
        XCTAssertEqual(settings.backgroundBlur, 31)
        XCTAssertEqual(settings.appearanceMode, .macOSSystem)
        XCTAssertEqual(settings.systemLightThemeName, "GitHub Light")
        XCTAssertEqual(settings.systemDarkThemeName, "Dracula")
        XCTAssertEqual(settings.importedConfigSignature, "signature")
        XCTAssertEqual(settings.prefixKey, "ctrl-b")
        XCTAssertEqual(settings.scrollbackLines, 12345)
        XCTAssertEqual(settings.cursorStyle, "underline")
        XCTAssertFalse(settings.cursorBlink)
        XCTAssertFalse(settings.copyOnSelect)
        XCTAssertTrue(settings.paletteHex.allSatisfy { $0 == nil })
        XCTAssertEqual(settings.agentColorOverrides, ["codex": "#123456"])
        XCTAssertFalse(settings.systemNotificationsEnabled)
        XCTAssertFalse(settings.notificationSoundEnabled)
        XCTAssertEqual(settings.colorRendering, .vivid)
        XCTAssertEqual(settings.colorGamut, .displayP3)
        XCTAssertEqual(settings.textRendering, .crisp)
        XCTAssertTrue(settings.vividColors)
        XCTAssertTrue(settings.linearBlending)
        XCTAssertTrue(settings.applyThemeToTerminalOutput)
        XCTAssertFalse(settings.ligatures)
        XCTAssertFalse(settings.offMainParserFramePipeline)
        XCTAssertTrue(settings.showPromptGutter)
        XCTAssertFalse(settings.showStatusLine)
        XCTAssertEqual(settings.experienceMode, .agent)
        XCTAssertEqual(settings.harnessControlsEnabled, true)
    }

    func testSwitchingIntoFollowSystemSeedsOnlyUnsetThemeNames() throws {
        let source = try settingsViewControllerSource()

        XCTAssertTrue(source.contains("previousAppearanceMode != .macOSSystem && nextAppearanceMode == .macOSSystem"))
        XCTAssertTrue(source.contains("settings.systemLightThemeName.trimmingCharacters"))
        XCTAssertTrue(source.contains("settings.systemLightThemeName = ThemeManager.defaultSystemLightThemeName"))
        XCTAssertTrue(source.contains("settings.systemDarkThemeName.trimmingCharacters"))
        XCTAssertTrue(source.contains("settings.systemDarkThemeName = selectedThemeName"))

        var seeded = HarnessSettings(
            appearanceMode: .theme,
            systemLightThemeName: "",
            systemDarkThemeName: ""
        )
        seedUnsetSystemThemeNames(&seeded, selectedThemeName: "Dracula", validThemeNames: ["Dracula"])
        XCTAssertEqual(seeded.systemLightThemeName, "Zenwritten Light")
        XCTAssertEqual(seeded.systemDarkThemeName, "Dracula")

        var preserved = HarnessSettings(
            appearanceMode: .theme,
            systemLightThemeName: "GitHub Light",
            systemDarkThemeName: "Tokyo Night"
        )
        seedUnsetSystemThemeNames(&preserved, selectedThemeName: "Dracula", validThemeNames: ["Dracula"])
        XCTAssertEqual(preserved.systemLightThemeName, "GitHub Light")
        XCTAssertEqual(preserved.systemDarkThemeName, "Tokyo Night")
    }

    func testReimportDoesNotSendRawSplitThemeToSetTheme() throws {
        let source = try sessionCoordinatorSource()
        let reimport = try sourceBlock(named: "reimportTerminalConfig", in: source)

        XCTAssertTrue(reimport.contains("imported.themeName ?? imported.systemDarkThemeName"))
        XCTAssertTrue(reimport.contains("setTheme(displayTheme, seedColors: false)"))
        XCTAssertFalse(reimport.contains("setTheme(imported.themeName"))
    }

    private struct PersistedSystemThemeSelection {
        var themeName: String
        var systemLightThemeName: String
        var systemDarkThemeName: String

        func selecting(light: String, dark: String) -> Self {
            Self(
                themeName: themeName,
                systemLightThemeName: light,
                systemDarkThemeName: dark
            )
        }
    }

    private func seedUnsetSystemThemeNames(
        _ settings: inout HarnessSettings,
        selectedThemeName: String,
        validThemeNames: Set<String>
    ) {
        if settings.systemLightThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.systemLightThemeName = "Zenwritten Light"
        }
        if settings.systemDarkThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           validThemeNames.contains(selectedThemeName) {
            settings.systemDarkThemeName = selectedThemeName
        }
    }

    private func sourceBlock(named functionName: String, in source: String) throws -> String {
        let marker = "func \(functionName)"
        guard let markerRange = source.range(of: marker),
              let bodyStart = source[markerRange.upperBound...].firstIndex(of: "{")
        else {
            XCTFail("Missing function \(functionName)")
            return ""
        }

        var depth = 0
        var index = bodyStart
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[bodyStart...index])
                }
            }
            index = source.index(after: index)
        }
        XCTFail("Unterminated function \(functionName)")
        return ""
    }

    private func settingsViewControllerSource() throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Apps/Harness/Sources/HarnessApp/Settings/SettingsViewController.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sessionCoordinatorSource() throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
