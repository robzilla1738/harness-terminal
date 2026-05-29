import XCTest
@testable import HarnessTerminalRenderer
import HarnessTerminalEngine
import HarnessTheme

final class ANSIPaletteTests: XCTestCase {
    private let palette = ANSIPalette(base16: HarnessThemeCatalog.theme(named: "Dracula")!.palette)

    func testBaseSixteenComeFromTheme() {
        let base = HarnessThemeCatalog.theme(named: "Dracula")!.palette
        for i in 0 ..< 16 {
            XCTAssertEqual(palette.color(at: i), base[i], "base color \(i)")
        }
    }

    func testColorCubeCorners() {
        // 16 = (0,0,0); 231 = (255,255,255).
        XCTAssertEqual(palette.color(at: 16), RGBColor(red: 0, green: 0, blue: 0))
        XCTAssertEqual(palette.color(at: 231), RGBColor(red: 255, green: 255, blue: 255))
    }

    func testColorCubePureRed() {
        // r=5,g=0,b=0 -> index 16 + 36*5 = 196 -> (255,0,0).
        XCTAssertEqual(palette.color(at: 196), RGBColor(red: 255, green: 0, blue: 0))
    }

    func testColorCubeLowLevel() {
        // r=g=b=1 -> index 16 + 36 + 6 + 1 = 59 -> (95,95,95).
        XCTAssertEqual(palette.color(at: 59), RGBColor(red: 95, green: 95, blue: 95))
    }

    func testGrayscaleRamp() {
        XCTAssertEqual(palette.color(at: 232), RGBColor(red: 8, green: 8, blue: 8))
        XCTAssertEqual(palette.color(at: 255), RGBColor(red: 238, green: 238, blue: 238))
    }

    func testIndexClamping() {
        XCTAssertEqual(palette.color(at: -5), palette.color(at: 0))
        XCTAssertEqual(palette.color(at: 999), palette.color(at: 255))
    }
}

final class CellColorResolverTests: XCTestCase {
    private let theme = HarnessThemeCatalog.theme(named: "Dracula")!
    private var resolver: CellColorResolver { CellColorResolver(theme: theme) }

    func testDefaultsWhenUnset() {
        let r = resolver.resolve(TerminalGridCell(codepoint: 0x41))
        XCTAssertEqual(r.foreground, theme.foreground)
        XCTAssertEqual(r.background, theme.background)
    }

    func testPaletteForeground() {
        let r = resolver.resolve(TerminalGridCell(codepoint: 0x41, foreground: .palette(4)))
        XCTAssertEqual(r.foreground, theme.palette[4])
    }

    func testTrueColorPassesThrough() {
        let r = resolver.resolve(TerminalGridCell(codepoint: 0x41, foreground: .rgb(r: 1, g: 2, b: 3)))
        XCTAssertEqual(r.foreground, RGBColor(red: 1, green: 2, blue: 3))
    }

    func testBoldBrightensLowPalette() {
        // Bold + fg palette 1 -> bright variant (palette 9).
        let r = resolver.resolve(TerminalGridCell(codepoint: 0x41, foreground: .palette(1), bold: true))
        XCTAssertEqual(r.foreground, theme.palette[9])
    }

    func testBoldDoesNotBrightenTrueColor() {
        let r = resolver.resolve(TerminalGridCell(codepoint: 0x41, foreground: .rgb(r: 10, g: 20, b: 30), bold: true))
        XCTAssertEqual(r.foreground, RGBColor(red: 10, green: 20, blue: 30))
    }

    func testBoldBrightenDisabled() {
        let plain = CellColorResolver(theme: theme, boldBrightens: false)
        let r = plain.resolve(TerminalGridCell(codepoint: 0x41, foreground: .palette(1), bold: true))
        XCTAssertEqual(r.foreground, theme.palette[1])
    }

    func testFaintDimsTowardBackground() {
        let cell = TerminalGridCell(codepoint: 0x41, foreground: .palette(7), faint: true)
        let expected = theme.palette[7].blended(toward: theme.background, fraction: 0.5)
        XCTAssertEqual(resolver.resolve(cell).foreground, expected)
    }

    func testInverseSwapsForegroundAndBackground() {
        let cell = TerminalGridCell(codepoint: 0x41, foreground: .palette(1), background: .palette(4), inverse: true)
        let r = resolver.resolve(cell)
        XCTAssertEqual(r.foreground, theme.palette[4])
        XCTAssertEqual(r.background, theme.palette[1])
    }

    func testInvisibleMatchesForegroundToBackground() {
        let cell = TerminalGridCell(codepoint: 0x41, foreground: .palette(1), background: .palette(4), invisible: true)
        let r = resolver.resolve(cell)
        XCTAssertEqual(r.foreground, r.background)
        XCTAssertEqual(r.foreground, theme.palette[4])
    }
}
