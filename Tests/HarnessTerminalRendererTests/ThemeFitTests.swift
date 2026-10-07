import XCTest
import HarnessTerminalEngine
import HarnessTheme
@testable import HarnessTerminalRenderer

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

    func testThreeKnownPairsLockTheirAdjustedBytes() {
        let cache = ThemeFitCache()
        let pairs: [(HarnessTheme.RGBColor, HarnessTheme.RGBColor, HarnessTheme.RGBColor)] = [
            (HarnessTheme.RGBColor(red: 40, green: 40, blue: 40),
             HarnessTheme.RGBColor(red: 20, green: 20, blue: 24),
             HarnessTheme.RGBColor(red: 120, green: 180, blue: 255)),
            (HarnessTheme.RGBColor(red: 180, green: 180, blue: 180),
             HarnessTheme.RGBColor(red: 210, green: 210, blue: 210),
             HarnessTheme.RGBColor(red: 30, green: 60, blue: 140)),
            (HarnessTheme.RGBColor(red: 90, green: 90, blue: 100),
             HarnessTheme.RGBColor(red: 70, green: 72, blue: 80),
             HarnessTheme.RGBColor(red: 255, green: 196, blue: 80)),
        ]
        let locked = pairs.map { fg, bg, theme in
            let fitted = cache.adjust(foreground: fg, background: bg, toward: theme)
            XCTAssertLessThan(CellColorResolver.contrastRatio(fg, bg), 4.5)
            XCTAssertGreaterThanOrEqual(CellColorResolver.contrastRatio(fitted, bg), 4.5)
            XCTAssertNotEqual(fitted, fg)
            let again = cache.adjust(foreground: fg, background: bg, toward: theme)
            XCTAssertEqual(again, fitted)
            return "\(fitted.red),\(fitted.green),\(fitted.blue)"
        }
        XCTAssertGreaterThanOrEqual(cache.hitCount, 3)
        XCTAssertEqual(locked, ["126,126,126", "0,0,0", "193,179,180"])

        for (fg, bg, theme) in pairs {
            var resolver = CellColorResolver(
                palette: ANSIPalette(base16: Array(repeating: HarnessTheme.RGBColor(red: 136, green: 136, blue: 136), count: 16)),
                defaultForeground: theme,
                defaultBackground: bg,
                themeFit: false,
                themeFitTarget: theme
            )
            var cell = TerminalGridCell()
            cell.foreground = .rgb(r: fg.red, g: fg.green, b: fg.blue)
            cell.background = .rgb(r: bg.red, g: bg.green, b: bg.blue)
            XCTAssertEqual(resolver.resolve(cell).foreground, fg)
        }
    }
}
