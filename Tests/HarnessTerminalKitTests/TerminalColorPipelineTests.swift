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

    func testTerminalConfigOmitsBackgroundBlurAndKeepsOpacity() {
        // Blur is applied once at the window level (CGS, MainWindowController), never
        // per-surface — libghostty's background-blur is a no-op in embedded mode and
        // would double the chrome blur. The terminal config must carry opacity but
        // not blur.
        var settings = HarnessSettings()
        settings.backgroundBlur = 40
        settings.backgroundOpacity = 0.8
        let rendered = TerminalHostView.makeTerminalConfiguration(settings: settings, themeName: "Catppuccin Mocha").rendered
        XCTAssertFalse(
            rendered.contains("background-blur ="),
            "Terminal must not blur per-surface; window-level CGS blur is the single source"
        )
        XCTAssertTrue(rendered.contains("background-opacity = 0.8"))
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

    func testTerminalConfigurationRendersFullColorOverrides() {
        // Full Ghostty parity: every saved color must reach libghostty.
        var settings = HarnessSettings()
        settings.customBackgroundHex = "#000000"
        settings.customForegroundHex = "#ffffff"
        settings.customCursorHex = "#ffffff"
        settings.cursorTextHex = "#010101"
        settings.selectionBackgroundHex = "#222222"
        settings.selectionForegroundHex = "#eeeeee"
        settings.boldColorHex = "#ff0000"
        settings.minimumContrast = 1 // off → must NOT render
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
        XCTAssertTrue(config.rendered.contains("cursor-text = #010101"))
        XCTAssertTrue(config.rendered.contains("selection-background = #222222"))
        XCTAssertTrue(config.rendered.contains("selection-foreground = #eeeeee"))
        XCTAssertTrue(config.rendered.contains("bold-color = #ff0000"))
        XCTAssertTrue(config.rendered.contains("palette = 0=#111111"))
        XCTAssertTrue(config.rendered.contains("palette = 15=#ffffff"))
        XCTAssertFalse(config.rendered.contains("minimum-contrast ="))
        for line in TerminalColorPipeline.requiredRenderedConfigLines {
            XCTAssertTrue(config.rendered.contains(line))
        }
    }

    func testMinimumContrastRendersOnlyWhenAboveOne() {
        var settings = HarnessSettings()
        settings.minimumContrast = 1.5
        let config = TerminalHostView.makeTerminalConfiguration(settings: settings, themeName: "Catppuccin Mocha")
        XCTAssertTrue(config.rendered.contains("minimum-contrast = 1.5"))
    }

    func testThemePresetExposesFullPalette() {
        // A named theme must surface a complete preset so it can seed settings.
        let preset = ThemeManager.presetColors(themeName: "Dracula")
        XCTAssertNotNil(preset.backgroundHex)
        XCTAssertNotNil(preset.foregroundHex)
        XCTAssertEqual(preset.paletteHex.count, 16)
        XCTAssertNotNil(preset.paletteHex[0])
    }

    func testTerminalBackgroundEqualsResolvedCanvas() {
        // Single source of truth: the terminal must render exactly the canvas
        // color the resolver returns (the same value the chrome consumes), so
        // the sidebar and terminal can never drift into a visible seam.
        let themeName = "Dracula"
        let settings = HarnessSettings() // no custom hex → falls back to theme preset
        let canvas = ThemeManager.resolvedCanvas(
            themeName: themeName,
            customBackgroundHex: settings.customBackgroundHex,
            customForegroundHex: settings.customForegroundHex,
            customCursorHex: settings.customCursorHex
        )
        let rendered = TerminalHostView.makeTerminalConfiguration(settings: settings, themeName: themeName).rendered
        XCTAssertTrue(
            rendered.contains("background = \(canvas.backgroundHex)"),
            "Terminal background must equal the resolved canvas background \(canvas.backgroundHex); got:\n\(rendered)"
        )
        XCTAssertTrue(rendered.contains("foreground = \(canvas.foregroundHex)"))
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
