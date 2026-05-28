import XCTest
@testable import HarnessTerminalKit
import HarnessCore

@MainActor
final class TerminalColorPipelineTests: XCTestCase {
    func testTerminalConfigurationIncludesColorPipelineKeys() {
        let settings = HarnessSettings(
            backgroundOpacity: 0.72,
            backgroundBlur: 24,
            customBackgroundHex: "#000000",
            customForegroundHex: "#ffffff",
            customCursorHex: "#ffffff"
        )

        let rendered = TerminalHostView.makeTerminalConfiguration(settings: settings).rendered

        for line in TerminalColorPipeline.requiredRenderedConfigLines {
            XCTAssertTrue(rendered.contains(line), "Missing \(line)\n\(rendered)")
        }
        XCTAssertTrue(rendered.contains("background-opacity = 0.72"), rendered)
        XCTAssertTrue(rendered.contains("background-blur = 24"), rendered)
        XCTAssertTrue(rendered.contains("background = #000000"), rendered)
        XCTAssertTrue(rendered.contains("foreground = #ffffff"), rendered)
        XCTAssertTrue(rendered.contains("cursor-color = #ffffff"), rendered)
    }

    func testTerminalConfigurationIgnoresThemeAndAdvancedColorOverrides() {
        var settings = HarnessSettings(
            customBackgroundHex: "#010203",
            customForegroundHex: "#fefefe",
            customCursorHex: "#ababab",
            useCustomColors: true,
            selectionBackgroundHex: "#111111",
            selectionForegroundHex: "#222222",
            boldColorHex: "#333333",
            cursorTextHex: "#444444",
            minimumContrast: 7,
            paletteHex: (0 ..< 16).map { String(format: "#%06X", $0) }
        )
        settings.paletteHex[1] = "#FF0000"

        let rendered = TerminalHostView.makeTerminalConfiguration(settings: settings).rendered

        XCTAssertTrue(rendered.contains("background = #010203"), rendered)
        XCTAssertTrue(rendered.contains("foreground = #fefefe"), rendered)
        XCTAssertTrue(rendered.contains("cursor-color = #ababab"), rendered)
        XCTAssertFalse(rendered.contains("palette ="), rendered)
        XCTAssertFalse(rendered.contains("bold-color ="), rendered)
        XCTAssertFalse(rendered.contains("selection-background ="), rendered)
        XCTAssertFalse(rendered.contains("selection-foreground ="), rendered)
        XCTAssertFalse(rendered.contains("cursor-text ="), rendered)
        XCTAssertFalse(rendered.contains("minimum-contrast ="), rendered)
    }
}
