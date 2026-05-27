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
}
