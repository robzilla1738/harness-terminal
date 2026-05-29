import Foundation
import XCTest
@testable import HarnessTheme

final class RGBColorTests: XCTestCase {
    func testParsesSixDigitHex() {
        let c = RGBColor(hex: "#1e1e2e")
        XCTAssertEqual(c, RGBColor(red: 0x1e, green: 0x1e, blue: 0x2e))
    }

    func testParsesWithoutHash() {
        XCTAssertEqual(RGBColor(hex: "ff8800"), RGBColor(red: 255, green: 136, blue: 0))
    }

    func testParsesShorthand() {
        XCTAssertEqual(RGBColor(hex: "#f80"), RGBColor(red: 0xff, green: 0x88, blue: 0x00))
    }

    func testParsesAlpha() {
        let c = RGBColor(hex: "#11223380")
        XCTAssertEqual(c, RGBColor(red: 0x11, green: 0x22, blue: 0x33, alpha: 0x80))
    }

    func testRejectsMalformed() {
        XCTAssertNil(RGBColor(hex: "#xyz"))
        XCTAssertNil(RGBColor(hex: "#12345"))
        XCTAssertNil(RGBColor(hex: ""))
    }

    func testHexRoundTrip() {
        XCTAssertEqual(RGBColor(hex: "#1e1e2e")?.hexString, "#1e1e2e")
        XCTAssertEqual(RGBColor(hex: "#11223380")?.hexString, "#11223380")
    }

    func testBrightnessClassification() {
        XCTAssertTrue(RGBColor(hex: "#000000")!.isDark)
        XCTAssertFalse(RGBColor(hex: "#ffffff")!.isDark)
    }

    func testCodableUsesHexString() throws {
        let color = RGBColor(hex: "#89b4fa")!
        let data = try JSONEncoder().encode(color)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"#89b4fa\"")
        let decoded = try JSONDecoder().decode(RGBColor.self, from: data)
        XCTAssertEqual(decoded, color)
    }
}

final class HarnessThemeCatalogTests: XCTestCase {
    func testDefaultThemeExists() {
        XCTAssertNotNil(HarnessThemeCatalog.theme(named: HarnessThemeCatalog.defaultThemeName))
    }

    func testAllFeaturedThemesPresent() {
        for name in HarnessThemeCatalog.featuredNames {
            XCTAssertNotNil(HarnessThemeCatalog.theme(named: name), "missing featured theme \(name)")
        }
    }

    func testLookupIsCaseInsensitive() {
        XCTAssertNotNil(HarnessThemeCatalog.theme(named: "dracula"))
        XCTAssertNotNil(HarnessThemeCatalog.theme(named: "DRACULA"))
    }

    func testEveryThemeHasSixteenColorPalette() {
        for theme in HarnessThemeCatalog.allThemes {
            XCTAssertEqual(theme.palette.count, 16, "\(theme.name) palette is not 16 colors")
        }
    }

    func testSearchEmptyReturnsAll() {
        XCTAssertEqual(HarnessThemeCatalog.search("").count, HarnessThemeCatalog.allThemes.count)
    }

    func testSearchFiltersByName() {
        let results = HarnessThemeCatalog.search("tokyo")
        // Robust to catalog size: the query must filter (fewer than all), every result
        // must match it, and the canonical theme must be present.
        XCTAssertFalse(results.isEmpty)
        XCTAssertLessThan(results.count, HarnessThemeCatalog.allThemes.count)
        XCTAssertTrue(results.allSatisfy { $0.name.lowercased().contains("tokyo") })
        XCTAssertTrue(results.contains { $0.name == "Tokyo Night" })
    }

    func testDarkThemesAreClassifiedDark() {
        XCTAssertTrue(HarnessThemeCatalog.theme(named: "Catppuccin Mocha")!.isDark)
    }
}

final class ThemeDocumentTests: XCTestCase {
    private func sampleDocument() -> ThemeDocument {
        let def = HarnessThemeCatalog.theme(named: "Dracula")!
        let appearance = ThemeDocument.Appearance(
            backgroundOpacity: 0.95,
            backgroundBlur: 20,
            fontFamily: "JetBrains Mono",
            fontSize: 14,
            applyToTerminalOutput: true
        )
        return ThemeDocument(definition: def, appearance: appearance, author: "robert")
    }

    func testRoundTripPreservesContent() throws {
        let doc = sampleDocument()
        let data = try doc.encoded()
        let restored = try ThemeDocument.decoded(from: data)
        XCTAssertEqual(restored, doc)
    }

    func testEncodedJSONUsesHexColors() throws {
        let data = try sampleDocument().encoded()
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("#282a36"), "background hex should appear in JSON")
        XCTAssertTrue(json.contains("\"applyToTerminalOutput\""))
    }

    func testDefinitionConversionRoundTrip() {
        let def = HarnessThemeCatalog.theme(named: "Nord")!
        let doc = ThemeDocument(definition: def)
        XCTAssertEqual(doc.themeDefinition, def)
    }

    func testRejectsUnsupportedVersion() {
        var doc = sampleDocument()
        doc.version = ThemeDocument.currentVersion + 1
        XCTAssertThrowsError(try doc.encoded()) { error in
            XCTAssertEqual(error as? ThemeDocumentError, .unsupportedVersion(doc.version))
        }
    }

    func testRejectsWrongPaletteCount() {
        var doc = sampleDocument()
        doc.colors.palette = Array(doc.colors.palette.prefix(8))
        XCTAssertThrowsError(try doc.encoded()) { error in
            XCTAssertEqual(error as? ThemeDocumentError, .wrongPaletteCount(8))
        }
    }

    func testRejectsEmptyName() {
        var doc = sampleDocument()
        doc.name = "   "
        XCTAssertThrowsError(try doc.encoded()) { error in
            XCTAssertEqual(error as? ThemeDocumentError, .emptyName)
        }
    }

    func testDecodeMalformedThrows() {
        let garbage = Data("not json".utf8)
        XCTAssertThrowsError(try ThemeDocument.decoded(from: garbage))
    }
}
