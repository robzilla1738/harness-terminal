import HarnessCore
import HarnessTerminalRenderer
import HarnessTheme
import XCTest
@testable import HarnessTerminalKit

final class TerminalHostViewTests: XCTestCase {
    @MainActor
    func testTerminalOverlayIndicatorsUseQuietMacPaneRadius() {
        XCTAssertEqual(TerminalHostView.terminalOverlayCornerRadius, 10)
    }


    @MainActor
    func testChromeAndHostCanvasMoveFromStaleDarkOverrideToSelectedSystemLightAfterReset() throws {
        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Zenwritten Light"))
        var settings = HarnessSettings(
            appearanceMode: .macOSSystem,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Harness Default",
            customBackgroundHex: "#000000",
            customForegroundHex: "#111111",
            customCursorHex: "#222222",
            selectionBackgroundHex: "#333333",
            selectionForegroundHex: "#444444",
            boldColorHex: "#555555",
            cursorTextHex: "#666666",
            dividerHex: "#777777",
            statusLineHex: "#888888"
        )

        let staleHost = TerminalHostView.resolvedNativeAppearance(
            themeName: "Dracula",
            settings: settings,
            systemAppearance: .light
        )
        XCTAssertEqual(staleHost.canvasBackgroundHex, "#000000")

        settings.clearThemeColorOverrides()
        let resetHost = TerminalHostView.resolvedNativeAppearance(
            themeName: "Dracula",
            settings: settings,
            systemAppearance: .light
        )

        XCTAssertEqual(resetHost.canvasBackgroundHex, lightTheme.backgroundHex)
        XCTAssertEqual(resetHost.canvasForegroundHex, lightTheme.foregroundHex)
        XCTAssertEqual(resetHost.cursorHex, lightTheme.cursorHex ?? lightTheme.foregroundHex)

        let chromeSource = try sourceFile("Apps/Harness/Sources/HarnessApp/UI/HarnessChrome.swift")
        XCTAssertTrue(chromeSource.contains("let canvas = ThemeManager.resolvedCanvas("))
        XCTAssertTrue(chromeSource.contains("current = HarnessChromePalette.from("))

        let coordinatorSource = try sourceFile("Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift")
        let refreshChrome = try sourceBlock(named: "refreshChromePalette", in: coordinatorSource)
        XCTAssertTrue(refreshChrome.contains("appearanceMode: settings.appearanceMode"))
        XCTAssertTrue(refreshChrome.contains("systemLightThemeName: settings.systemLightThemeName"))
        XCTAssertTrue(refreshChrome.contains("backgroundHex: settings.customBackgroundHex"))
        XCTAssertTrue(refreshChrome.contains("foregroundHex: settings.customForegroundHex"))
        XCTAssertTrue(refreshChrome.contains("cursorHex: settings.customCursorHex"))

        // applySettingsToHosts routes through the shared updateChromeAndHosts loop (main's
        // factoring), which in turn goes through the appearance-aware refreshChromePalette().
        let applySettings = try sourceBlock(named: "applySettingsToHosts", in: coordinatorSource)
        XCTAssertTrue(applySettings.contains("updateChromeAndHosts()"))
        XCTAssertTrue(applySettings.contains("\"chromeChanged\": true"))
        let updateChromeAndHosts = try sourceBlock(named: "updateChromeAndHosts", in: coordinatorSource)
        // Parameterized so the OS-flip path can pass the freshly-read system appearance
        // (nil default = resolve live, the settings-apply path's behavior).
        XCTAssertTrue(updateChromeAndHosts.contains("refreshChromePalette(systemAppearance: systemAppearance)"))
        XCTAssertTrue(updateChromeAndHosts.contains("host.applySettings(settings)"))
    }

    private func sourceFile(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
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
}
