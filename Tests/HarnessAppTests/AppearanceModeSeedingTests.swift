import XCTest
@testable import HarnessApp
import HarnessCore
import HarnessTerminalKit

/// The Settings toggle to "Follow macOS Appearance" seeds the system light/dark theme
/// names only when they are unset — switching modes must never clobber a choice the
/// user already made.
@MainActor
final class AppearanceModeSeedingTests: XCTestCase {
    func testSeedsOnlyUnsetNames() {
        var settings = HarnessSettings()
        settings.systemLightThemeName = ""
        settings.systemDarkThemeName = "  "
        SettingsViewController.seedUnsetSystemThemeNames(settings: &settings, selectedThemeName: "Dracula")
        XCTAssertEqual(settings.systemLightThemeName, ThemeManager.defaultSystemLightThemeName)
        XCTAssertEqual(settings.systemDarkThemeName, "Dracula",
                       "the active theme becomes the dark half when none was chosen")
    }

    func testSetNamesSurviveTheToggle() {
        var settings = HarnessSettings()
        settings.systemLightThemeName = "GitHub Light"
        settings.systemDarkThemeName = "Harness Default"
        SettingsViewController.seedUnsetSystemThemeNames(settings: &settings, selectedThemeName: "Dracula")
        XCTAssertEqual(settings.systemLightThemeName, "GitHub Light")
        XCTAssertEqual(settings.systemDarkThemeName, "Harness Default")
    }

    func testUnknownSelectedThemeFallsBackForDarkHalf() {
        var settings = HarnessSettings()
        settings.systemDarkThemeName = ""
        SettingsViewController.seedUnsetSystemThemeNames(settings: &settings, selectedThemeName: "No Such Theme")
        XCTAssertEqual(settings.systemDarkThemeName, "",
                       "an unknown active theme must not be seeded into the dark slot")
    }
}
