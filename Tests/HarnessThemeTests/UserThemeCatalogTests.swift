import XCTest
@testable import HarnessTheme

final class UserThemeCatalogTests: XCTestCase {
    override func tearDown() {
        HarnessThemeCatalog.userThemes = []
    }

    func testSavedThemesListAndResolveButNeverShadowABuiltin() {
        let palette = (0 ..< 16).map { _ in RGBColor(hex: "#112233")! }
        let document = ThemeDocument(name: "My Night", colors: .init(
            background: RGBColor(hex: "#000011")!, foreground: RGBColor(hex: "#eeeeee")!, palette: palette
        ))
        let impostor = ThemeDocument(name: "Dracula", colors: document.colors)
        HarnessThemeCatalog.userThemes = [document, impostor].map(HarnessThemeDefinition.init(document:))
        XCTAssertEqual(HarnessThemeCatalog.theme(named: "my night")?.backgroundHex, "#000011")
        XCTAssertTrue(HarnessThemeCatalog.allThemes.contains { $0.name == "My Night" })
        XCTAssertNotEqual(HarnessThemeCatalog.theme(named: "Dracula")?.backgroundHex, "#000011", "a builtin keeps its colors")
        XCTAssertEqual(HarnessThemeCatalog.allThemes.filter { $0.name == "Dracula" }.count, 1)
    }
}
