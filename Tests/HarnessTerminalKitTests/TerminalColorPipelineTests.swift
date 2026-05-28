import GhosttyTerminal
import HarnessCore
@testable import HarnessTerminalKit
import XCTest

@MainActor
final class TerminalColorPipelineTests: XCTestCase {
    func testRenderedConfigIncludesColorPipelineKeys() {
        let config = TerminalConfiguration {
            TerminalColorPipeline.apply(to: &$0)
            $0.withFontSize(13)
            $0.withFontFamily("Menlo")
        }
        let rendered = config.rendered
        for line in TerminalColorPipeline.requiredRenderedConfigLines {
            XCTAssertTrue(
                rendered.contains(line),
                "Expected rendered config to contain \"\(line)\"; got:\n\(rendered)"
            )
        }
    }

    func testControllerGeneratedConfigIncludesColorPipelineKeys() {
        let controller = TerminalController {
            TerminalColorPipeline.apply(to: &$0)
        }
        let rendered = controller.renderedConfig
        for line in TerminalColorPipeline.requiredRenderedConfigLines {
            XCTAssertTrue(
                rendered.contains(line),
                "Expected controller rendered config to contain \"\(line)\"; got:\n\(rendered)"
            )
        }
    }

    func testHarnessTerminalBlockIncludesBackgroundBlur() {
        let config = TerminalConfiguration {
            ThemeManager.configureBuilder(&$0, themeName: ThemeManager.defaultThemeName)
            TerminalColorPipeline.apply(to: &$0)
            $0.withBackgroundBlur(20)
        }
        XCTAssertTrue(
            config.rendered.contains("background-blur = 20"),
            "Terminal blur must use libghostty background-blur, not window CGS blur"
        )
    }

    func testThemesDoNotSeedTerminalPaletteOrBackground() {
        let config = TerminalConfiguration {
            ThemeManager.configureBuilder(&$0, themeName: ThemeManager.defaultDisplayName)
            TerminalColorPipeline.apply(to: &$0)
        }
        XCTAssertFalse(config.rendered.contains("background ="))
        XCTAssertFalse(config.rendered.contains("foreground ="))
        XCTAssertFalse(config.rendered.contains("palette ="))
    }

    func testNamedThemesDoNotAffectTerminalToolColors() {
        let config = TerminalConfiguration {
            ThemeManager.configureBuilder(&$0, themeName: "Catppuccin Mocha")
            TerminalColorPipeline.apply(to: &$0)
        }
        XCTAssertFalse(config.rendered.contains("background ="))
        XCTAssertFalse(config.rendered.contains("foreground ="))
        XCTAssertFalse(config.rendered.contains("selection-background ="))
        XCTAssertFalse(config.rendered.contains("selection-foreground ="))
        XCTAssertFalse(config.rendered.contains("cursor-color ="))
        XCTAssertFalse(config.rendered.contains("cursor-text ="))
        XCTAssertFalse(config.rendered.contains("bold-color ="))
        XCTAssertFalse(config.rendered.contains("palette ="))
        for line in TerminalColorPipeline.requiredRenderedConfigLines {
            XCTAssertTrue(config.rendered.contains(line))
        }
    }

    func testTerminalConfigurationIgnoresSavedPaletteAndBoldOverrides() {
        var settings = HarnessSettings()
        settings.useCustomColors = true
        settings.customBackgroundHex = "#000000"
        settings.customForegroundHex = "#ffffff"
        settings.customCursorHex = "#ffffff"
        settings.boldColorHex = "#ff0000"
        settings.paletteHex = [
            "#111111", "#222222", "#333333", "#444444",
            "#555555", "#666666", "#777777", "#888888",
            "#999999", "#aaaaaa", "#bbbbbb", "#cccccc",
            "#dddddd", "#eeeeee", "#fafafa", "#ffffff",
        ]

        let config = TerminalHostView.makeTerminalConfiguration(settings: settings, themeName: "Catppuccin Mocha")
        XCTAssertTrue(config.rendered.contains("background = #000000"))
        XCTAssertTrue(config.rendered.contains("foreground = #ffffff"))
        XCTAssertTrue(config.rendered.contains("cursor-color = #ffffff"))
        XCTAssertFalse(config.rendered.contains("bold-color ="))
        XCTAssertFalse(config.rendered.contains("palette ="))
        for line in TerminalColorPipeline.requiredRenderedConfigLines {
            XCTAssertTrue(config.rendered.contains(line))
        }
    }

    func testGhosttyConfigImporterExistingConfigPathWhenPresent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-ghostty-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configFile = directory.appendingPathComponent("config")
        try "background = #101010\n".write(to: configFile, atomically: true, encoding: .utf8)

        let path = GhosttyConfigImporter.existingConfigPath(from: [configFile.path])
        XCTAssertEqual(path, configFile.path)
    }

    func testControllerAcceptsMergedGhosttyConfigTemplateWithSpacedPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness ghostty config \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configFile = directory.appendingPathComponent("config.ghostty")
        try """
        background = #000000
        foreground = #ffffff
        font-size = 17
        """.write(to: configFile, atomically: true, encoding: .utf8)

        let template = try XCTUnwrap(GhosttyConfigImporter.mergedConfigTemplate(from: [configFile.path]))
        let controller = TerminalController(
            configSource: .generated(template),
            theme: TerminalTheme(),
            terminalConfiguration: TerminalConfiguration {
                TerminalColorPipeline.apply(to: &$0)
            }
        )

        XCTAssertNil(controller.lastConfigurationIssue)
        XCTAssertTrue(controller.renderedConfig.contains("config-file = \"\(configFile.path)\""))
        for line in TerminalColorPipeline.requiredRenderedConfigLines {
            XCTAssertTrue(controller.renderedConfig.contains(line))
        }
    }
}
