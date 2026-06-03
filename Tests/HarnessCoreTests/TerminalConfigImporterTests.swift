import XCTest
@testable import HarnessCore

final class TerminalConfigImporterTests: XCTestCase {
    func testCandidatePathsPreferModernThenLegacyNamesAcrossLocations() {
        let suffixes = TerminalConfigImporter.candidatePaths.map { path in
            path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }

        XCTAssertEqual(suffixes, [
            "~/.config/ghostty/config.ghostty",
            "~/.config/ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
        ])
    }

    func testDualAppearanceThemeImportsAsAutoLightDarkPair() {
        let imported = TerminalConfigImporter.parse("""
        theme = light:Catppuccin Latte,dark:Catppuccin Mocha
        """)
        XCTAssertEqual(imported.systemLightThemeName, "Catppuccin Latte")
        XCTAssertEqual(imported.systemDarkThemeName, "Catppuccin Mocha")
        // The dark variant doubles as the base theme so non-auto consumers stay sane.
        XCTAssertNil(imported.themeName)

        let settings = HarnessSettings.makeDefaults(imported: imported)
        XCTAssertEqual(settings.systemLightThemeName, "Catppuccin Latte")
        XCTAssertEqual(settings.systemDarkThemeName, "Catppuccin Mocha")
    }

    func testDualAppearanceThemeAcceptsReversedOrder() {
        let imported = TerminalConfigImporter.parse("""
        theme = dark:One Dark, light:One Light
        """)
        XCTAssertEqual(imported.systemLightThemeName, "One Light")
        XCTAssertEqual(imported.systemDarkThemeName, "One Dark")
        XCTAssertNil(imported.themeName)
    }

    func testSingleThemeStaysLiteralEvenWithColonInName() {
        // A lone light:/dark: prefix without its counterpart is not the dual form.
        let imported = TerminalConfigImporter.parse("""
        theme = Builtin Solarized Dark
        """)
        XCTAssertEqual(imported.themeName, "Builtin Solarized Dark")
        XCTAssertNil(imported.systemLightThemeName)
        XCTAssertNil(imported.systemDarkThemeName)
    }

    func testLaterSingleThemeOverrideClearsEarlierDualPairOnMerge() throws {
        // Two config files in merge order: the later single-theme override must clear
        // the earlier dual pair, not leave a stale auto light/dark pairing behind.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let earlier = dir.appendingPathComponent("config-early")
        let later = dir.appendingPathComponent("config-late")
        try "theme = light:A,dark:B".write(to: earlier, atomically: true, encoding: .utf8)
        try "theme = C".write(to: later, atomically: true, encoding: .utf8)

        let merged = try XCTUnwrap(TerminalConfigImporter.load(from: [earlier.path, later.path]))
        XCTAssertEqual(merged.themeName, "C")
        XCTAssertNil(merged.systemLightThemeName)
        XCTAssertNil(merged.systemDarkThemeName)
    }

    func testParsesExactVisualDefaults() {
        let imported = TerminalConfigImporter.parse("""
        # comment
        background = #000000
        foreground = #ffffff
        cursor-color = ffffff
        selection-background = #264f78
        selection-foreground = #ffffff
        bold-color = #eeeeee
        cursor-text = #000000
        minimum-contrast = 1
        palette = 0=#1d1f21
        palette = 1=#cc6666
        palette = 15=#eaeaea
        cursor-style = block
        cursor-style-blink = false
        copy-on-select = true
        font-family = JetBrainsMono Nerd Font
        font-size = 17
        window-padding-x = 14
        window-padding-y = 14
        background-opacity = 0.85
        background-blur = 12
        command = /opt/homebrew/bin/fish
        """)

        XCTAssertEqual(imported.backgroundHex, "#000000")
        XCTAssertEqual(imported.foregroundHex, "#FFFFFF")
        XCTAssertEqual(imported.cursorColorHex, "#FFFFFF")
        XCTAssertEqual(imported.selectionBackgroundHex, "#264F78")
        XCTAssertEqual(imported.selectionForegroundHex, "#FFFFFF")
        XCTAssertEqual(imported.boldColorHex, "#EEEEEE")
        XCTAssertEqual(imported.cursorTextHex, "#000000")
        XCTAssertEqual(imported.minimumContrast, 1)
        XCTAssertEqual(imported.paletteHex[0], "#1D1F21")
        XCTAssertEqual(imported.paletteHex[1], "#CC6666")
        XCTAssertEqual(imported.paletteHex[15], "#EAEAEA")
        XCTAssertEqual(imported.cursorStyle, "block")
        XCTAssertEqual(imported.cursorBlink, false)
        XCTAssertEqual(imported.copyOnSelect, true)
        XCTAssertTrue(imported.signature.hasPrefix("v6|"))
        XCTAssertEqual(imported.fontFamily, "JetBrainsMono Nerd Font")
        XCTAssertEqual(imported.fontSize, 17)
        XCTAssertEqual(imported.windowPaddingX, 14)
        XCTAssertEqual(imported.windowPaddingY, 14)
        XCTAssertEqual(imported.backgroundOpacity, 0.85)
        XCTAssertEqual(imported.backgroundBlur, 12)
        XCTAssertEqual(imported.defaultShell, "/opt/homebrew/bin/fish")
    }

    func testParsesGhosttySplitThemeAsSystemThemeNames() {
        let imported = TerminalConfigImporter.parse("""
        theme = dark:TokyoNight Storm,light:Tango Adapted
        """)

        XCTAssertNil(imported.themeName)
        XCTAssertEqual(imported.systemLightThemeName, "Tango Adapted")
        XCTAssertEqual(imported.systemDarkThemeName, "TokyoNight Storm")
    }

    func testParsesGhosttySplitThemeInAnyOrderAndWithQuotes() {
        let imported = TerminalConfigImporter.parse("""
        theme = "light:Tango Adapted,dark:TokyoNight Storm"
        """)

        XCTAssertNil(imported.themeName)
        XCTAssertEqual(imported.systemLightThemeName, "Tango Adapted")
        XCTAssertEqual(imported.systemDarkThemeName, "TokyoNight Storm")
    }


    func testKeepsSingleGhosttyThemeAsThemeName() {
        let imported = TerminalConfigImporter.parse("""
        theme = Dracula
        """)

        XCTAssertEqual(imported.themeName, "Dracula")
        XCTAssertNil(imported.systemLightThemeName)
        XCTAssertNil(imported.systemDarkThemeName)
    }

    func testMergesMultipleConfigLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-config-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let xdg = root.appendingPathComponent("xdg-config")
        let appSupport = root.appendingPathComponent("app-support-config")
        try """
        background = #000000
        foreground = #ffffff
        font-family = JetBrainsMono Nerd Font
        font-size = 15
        command = /bin/zsh
        """.write(to: xdg, atomically: true, encoding: .utf8)
        try """
        font-size = 17
        window-padding-x = 14
        window-padding-y = 14
        """.write(to: appSupport, atomically: true, encoding: .utf8)

        let imported = try XCTUnwrap(TerminalConfigImporter.load(from: [xdg.path, appSupport.path]))
        XCTAssertEqual(imported.backgroundHex, "#000000")
        XCTAssertEqual(imported.foregroundHex, "#FFFFFF")
        XCTAssertEqual(imported.fontFamily, "JetBrainsMono Nerd Font")
        XCTAssertEqual(imported.fontSize, 17)
        XCTAssertEqual(imported.windowPaddingX, 14)
        XCTAssertEqual(imported.windowPaddingY, 14)
        XCTAssertEqual(imported.defaultShell, "/bin/zsh")
    }
}
