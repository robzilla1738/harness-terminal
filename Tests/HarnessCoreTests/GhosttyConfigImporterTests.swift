import XCTest
@testable import HarnessCore

final class GhosttyConfigImporterTests: XCTestCase {
    func testCandidatePathsPreferModernThenLegacyNamesAcrossLocations() {
        let suffixes = GhosttyConfigImporter.candidatePaths.map { path in
            path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }

        XCTAssertEqual(suffixes, [
            "~/.config/ghostty/config.ghostty",
            "~/.config/ghostty/config",
            "~/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "~/Library/Application Support/com.mitchellh.ghostty/config",
        ])
    }

    func testParsesExactGhosttyVisualDefaults() {
        let imported = GhosttyConfigImporter.parse("""
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
        XCTAssertTrue(imported.signature.hasPrefix("v4|"))
        XCTAssertEqual(imported.fontFamily, "JetBrainsMono Nerd Font")
        XCTAssertEqual(imported.fontSize, 17)
        XCTAssertEqual(imported.windowPaddingX, 14)
        XCTAssertEqual(imported.windowPaddingY, 14)
        XCTAssertEqual(imported.backgroundOpacity, 0.85)
        XCTAssertEqual(imported.backgroundBlur, 12)
        XCTAssertEqual(imported.defaultShell, "/opt/homebrew/bin/fish")
    }

    func testMergedConfigTemplateIncludesExistingFilesInDiscoveryOrder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-ghostty-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let xdgModern = root.appendingPathComponent("config.ghostty")
        let missingLegacy = root.appendingPathComponent("config")
        let appSupportModern = root.appendingPathComponent("app-support-config.ghostty")
        let appSupportLegacy = root.appendingPathComponent("app-support-config")
        try "font-size = 15\n".write(to: xdgModern, atomically: true, encoding: .utf8)
        try "font-size = 16\n".write(to: appSupportModern, atomically: true, encoding: .utf8)
        try "font-size = 17\n".write(to: appSupportLegacy, atomically: true, encoding: .utf8)

        let template = try XCTUnwrap(GhosttyConfigImporter.mergedConfigTemplate(from: [
            xdgModern.path,
            missingLegacy.path,
            appSupportModern.path,
            appSupportLegacy.path,
        ]))

        XCTAssertEqual(template, """
        config-file = "\(xdgModern.path)"
        config-file = "\(appSupportModern.path)"
        config-file = "\(appSupportLegacy.path)"

        """)
    }

    func testMergesMultipleGhosttyConfigLocations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-ghostty-\(UUID().uuidString)", isDirectory: true)
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

        let imported = try XCTUnwrap(GhosttyConfigImporter.load(from: [xdg.path, appSupport.path]))
        XCTAssertEqual(imported.backgroundHex, "#000000")
        XCTAssertEqual(imported.foregroundHex, "#FFFFFF")
        XCTAssertEqual(imported.fontFamily, "JetBrainsMono Nerd Font")
        XCTAssertEqual(imported.fontSize, 17)
        XCTAssertEqual(imported.windowPaddingX, 14)
        XCTAssertEqual(imported.windowPaddingY, 14)
        XCTAssertEqual(imported.defaultShell, "/bin/zsh")
    }
}
