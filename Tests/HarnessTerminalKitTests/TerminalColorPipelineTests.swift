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

    func testTerminalRendersOpaqueAndOmitsBlur() {
        // The terminal surface ALWAYS renders fully opaque so its colors are true-Ghostty
        // rich and never washed — translucency/blur is a chrome-only effect applied at the
        // window level (CGS, MainWindowController). So the terminal config must (a) never
        // carry per-surface blur, and (b) force opacity 1.0 regardless of the user's
        // window-translucency setting.
        var settings = HarnessSettings()
        settings.backgroundBlur = 40
        settings.backgroundOpacity = 0.8
        let rendered = TerminalHostView.makeTerminalConfiguration(settings: settings, themeName: "Catppuccin Mocha").rendered
        XCTAssertFalse(
            rendered.contains("background-blur ="),
            "Terminal must not blur per-surface; window-level CGS blur is the single source"
        )
        XCTAssertFalse(
            rendered.contains("background-opacity = 0.8"),
            "Terminal must not inherit window translucency — it renders opaque for color fidelity"
        )
        XCTAssertTrue(
            rendered.contains("background-opacity = 1"),
            "Terminal opacity is forced to 1.0; got:\n\(rendered)"
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

    func testTerminalConfigurationRendersFullColorOverrides() {
        // Full Ghostty parity: every saved color must reach libghostty.
        // Pin sRGB so this exercises the explicit-sRGB path against
        // `requiredRenderedConfigLines` (the default is now vivid Display-P3).
        var settings = HarnessSettings()
        settings.vividColors = false
        settings.customBackgroundHex = "#000000"
        settings.customForegroundHex = "#ffffff"
        settings.customCursorHex = "#ffffff"
        settings.cursorTextHex = "#010101"
        settings.selectionBackgroundHex = "#222222"
        settings.selectionForegroundHex = "#eeeeee"
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

    func testDefaultColorRenderingIsVividP3() {
        // Out of the box: vivid Display-P3 so the renderer's wide gamut isn't
        // clamped (the washed-color fix), with macOS-native blending. Users can
        // switch to accurate sRGB in Settings ▸ Appearance.
        let rendered = TerminalHostView.makeTerminalConfiguration(settings: HarnessSettings(), themeName: "Catppuccin Mocha").rendered
        XCTAssertTrue(rendered.contains("window-colorspace = display-p3"))
        XCTAssertTrue(rendered.contains("alpha-blending = native"))
    }

    func testColorRenderingSettingsDriveConfig() {
        // The Settings picker must reach libghostty: accurate sRGB + gamma-correct blending.
        var settings = HarnessSettings()
        settings.vividColors = false
        settings.linearBlending = true
        let rendered = TerminalHostView.makeTerminalConfiguration(settings: settings, themeName: "Catppuccin Mocha").rendered
        XCTAssertTrue(rendered.contains("window-colorspace = srgb"))
        XCTAssertTrue(rendered.contains("alpha-blending = linear-corrected"))
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
