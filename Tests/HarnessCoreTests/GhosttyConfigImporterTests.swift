import XCTest
@testable import HarnessCore

final class GhosttyConfigImporterTests: XCTestCase {
    func testParsesExactGhosttyVisualDefaults() {
        let imported = GhosttyConfigImporter.parse("""
        # comment
        background = #000000
        foreground = #ffffff
        cursor-color = ffffff
        font-family = JetBrainsMono Nerd Font
        font-size = 17
        window-padding-x = 14
        window-padding-y = 14
        background-opacity = 0.85
        background-blur = 12
        command = /opt/homebrew/bin/fish
        """)

        XCTAssertEqual(imported.backgroundHex, "#000000")
        XCTAssertEqual(imported.foregroundHex, "#ffffff")
        XCTAssertEqual(imported.cursorColorHex, "#ffffff")
        XCTAssertEqual(imported.fontFamily, "JetBrainsMono Nerd Font")
        XCTAssertEqual(imported.fontSize, 17)
        XCTAssertEqual(imported.windowPaddingX, 14)
        XCTAssertEqual(imported.windowPaddingY, 14)
        XCTAssertEqual(imported.backgroundOpacity, 0.85)
        XCTAssertEqual(imported.backgroundBlur, 12)
        XCTAssertEqual(imported.defaultShell, "/opt/homebrew/bin/fish")
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
        XCTAssertEqual(imported.foregroundHex, "#ffffff")
        XCTAssertEqual(imported.fontFamily, "JetBrainsMono Nerd Font")
        XCTAssertEqual(imported.fontSize, 17)
        XCTAssertEqual(imported.windowPaddingX, 14)
        XCTAssertEqual(imported.windowPaddingY, 14)
        XCTAssertEqual(imported.defaultShell, "/bin/zsh")
    }
}
