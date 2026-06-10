import XCTest
import HarnessCore
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

    func testResolverBytesStayGamutFree() {
        let cell = TerminalGridCell(
            codepoint: 0x41,
            foreground: .rgb(r: 1, g: 2, b: 3),
            background: .rgb(r: 255, g: 0, b: 0)
        )
        let resolved = resolver.resolve(cell)

        for mode in [TerminalColorRenderingMode.accurate, .vivid] {
            _ = RenderColor(resolved.background, renderingMode: mode, gamut: .auto)
            XCTAssertEqual(resolver.resolve(cell), resolved)
            XCTAssertEqual(resolved.foreground, RGBColor(red: 1, green: 2, blue: 3))
            XCTAssertEqual(resolved.background, RGBColor(red: 255, green: 0, blue: 0))
        }
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

    // MARK: Minimum contrast (T5)

    func testContrastRatioBlackOnWhiteIsMax() {
        let white = HarnessTheme.RGBColor(red: 255, green: 255, blue: 255)
        let black = HarnessTheme.RGBColor(red: 0, green: 0, blue: 0)
        XCTAssertEqual(CellColorResolver.contrastRatio(black, white), 21, accuracy: 0.01)
        XCTAssertEqual(CellColorResolver.contrastRatio(white, white), 1, accuracy: 0.01)
    }

    func testMinimumContrastOfOneIsByteIdentical() {
        // ratio 1 = off: a low-contrast gray-on-gray cell is left exactly as the default resolver leaves it.
        let off = CellColorResolver(palette: ANSIPalette(base16: theme.palette),
                                    defaultForeground: theme.foreground, defaultBackground: theme.background)
        let on = CellColorResolver(palette: ANSIPalette(base16: theme.palette),
                                   defaultForeground: theme.foreground, defaultBackground: theme.background,
                                   minimumContrast: 1)
        let cell = TerminalGridCell(codepoint: 0x41,
                                    foreground: .rgb(r: 90, g: 90, b: 90), background: .rgb(r: 80, g: 80, b: 80))
        XCTAssertEqual(off.resolve(cell), on.resolve(cell))
    }

    func testMinimumContrastLiftsLowContrastForeground() {
        let resolver = CellColorResolver(palette: ANSIPalette(base16: theme.palette),
                                         defaultForeground: theme.foreground, defaultBackground: theme.background,
                                         minimumContrast: 7)
        // Dark gray text on a near-black background — well below ratio 7.
        let cell = TerminalGridCell(codepoint: 0x41,
                                    foreground: .rgb(r: 60, g: 60, b: 60), background: .rgb(r: 10, g: 10, b: 10))
        let r = resolver.resolve(cell)
        XCTAssertGreaterThanOrEqual(CellColorResolver.contrastRatio(r.foreground, r.background), 7 - 0.05)
        // The background is untouched; only the foreground is lifted (toward white on a dark bg).
        XCTAssertEqual(r.background, RGBColor(red: 10, green: 10, blue: 10))
        XCTAssertGreaterThan(Int(r.foreground.red), 60)
    }

    func testMinimumContrastSkipsConcealedCells() {
        let resolver = CellColorResolver(palette: ANSIPalette(base16: theme.palette),
                                         defaultForeground: theme.foreground, defaultBackground: theme.background,
                                         minimumContrast: 7)
        let cell = TerminalGridCell(codepoint: 0x41, foreground: .palette(1), background: .palette(4), invisible: true)
        let r = resolver.resolve(cell)
        XCTAssertEqual(r.foreground, r.background) // conceal still wins (fg == bg)
    }

    // MARK: - DECSCNM reverse video (DECSET 5)

    /// Reverse video swaps the screen's DEFAULT fg/bg (xterm semantics): default-colored
    /// cells invert; cells with explicit SGR colors keep them.
    func testReverseVideoSwapsDefaultsOnly() {
        var resolver = CellColorResolver(palette: ANSIPalette(base16: theme.palette),
                                         defaultForeground: theme.foreground,
                                         defaultBackground: theme.background)
        resolver.reverseVideo = true

        let plain = resolver.resolve(TerminalGridCell(codepoint: 0x41))
        XCTAssertEqual(plain.foreground, theme.background, "default fg renders as the old bg")
        XCTAssertEqual(plain.background, theme.foreground, "default bg renders as the old fg")

        let explicit = resolver.resolve(TerminalGridCell(
            codepoint: 0x41, foreground: .rgb(r: 10, g: 20, b: 30), background: .rgb(r: 40, g: 50, b: 60)
        ))
        XCTAssertEqual(explicit.foreground, RGBColor(red: 10, green: 20, blue: 30))
        XCTAssertEqual(explicit.background, RGBColor(red: 40, green: 50, blue: 60))
    }

    /// SGR inverse composes on top of the screen swap: an inverse default-colored cell under
    /// reverse video lands back on the normal default colors (double inversion).
    func testReverseVideoComposesWithCellInverse() {
        var resolver = CellColorResolver(palette: ANSIPalette(base16: theme.palette),
                                         defaultForeground: theme.foreground,
                                         defaultBackground: theme.background)
        resolver.reverseVideo = true
        let r = resolver.resolve(TerminalGridCell(codepoint: 0x41, inverse: true))
        XCTAssertEqual(r.foreground, theme.foreground)
        XCTAssertEqual(r.background, theme.background)
    }

    /// The default (`reverseVideo = false`) stays byte-identical to the pre-DECSCNM resolver.
    func testReverseVideoOffIsByteIdentical() {
        let resolver = CellColorResolver(palette: ANSIPalette(base16: theme.palette),
                                         defaultForeground: theme.foreground,
                                         defaultBackground: theme.background)
        let r = resolver.resolve(TerminalGridCell(codepoint: 0x41))
        XCTAssertEqual(r.foreground, theme.foreground)
        XCTAssertEqual(r.background, theme.background)
    }
}
