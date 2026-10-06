import XCTest
import HarnessTerminalEngine
import HarnessTheme
import HarnessTerminalRenderer

final class ThemeFitTests: XCTestCase {
    func testLowContrastPairIsAdjustedInOklabAndCached() {
        let cache = ThemeFitCache()
        let fg = HarnessTheme.RGBColor(red: 40, green: 40, blue: 40)
        let bg = HarnessTheme.RGBColor(red: 20, green: 20, blue: 24)
        let theme = HarnessTheme.RGBColor(red: 120, green: 180, blue: 255)
        let first = cache.adjust(foreground: fg, background: bg, toward: theme)
        let second = cache.adjust(foreground: fg, background: bg, toward: theme)
        XCTAssertEqual(first, second)
        XCTAssertGreaterThanOrEqual(cache.hitCount, 1, "the repeated pair reuses the cache")
        XCTAssertNotEqual(first, fg, "a low-contrast foreground moves toward the theme")

        var resolver = CellColorResolver(
            palette: ANSIPalette(base16: Array(repeating: HarnessTheme.RGBColor(red: 136, green: 136, blue: 136), count: 16)),
            defaultForeground: theme,
            defaultBackground: bg,
            themeFit: true,
            themeFitTarget: theme,
            themeFitCache: cache
        )
        var cell = TerminalGridCell()
        cell.foreground = .rgb(r: fg.red, g: fg.green, b: fg.blue)
        cell.background = .rgb(r: bg.red, g: bg.green, b: bg.blue)
        let fitted = resolver.resolve(cell)
        XCTAssertNotEqual(fitted.foreground, fg)

        resolver.themeFit = false
        let plain = resolver.resolve(cell)
        XCTAssertEqual(plain.foreground, fg, "full-theme recolor stays off; theme fit is the only adjustment")
    }
}
