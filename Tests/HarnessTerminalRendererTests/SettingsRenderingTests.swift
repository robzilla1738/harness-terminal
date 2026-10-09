import XCTest
import HarnessCore
import HarnessTerminalRenderer
import HarnessTheme

private typealias RGBColor = HarnessTheme.RGBColor

final class SettingsRenderingTests: XCTestCase {
    func testTextAndColorRenderingAreOrthogonal() {
        var settings = HarnessSettings()
        let source = RGBColor(red: 255, green: 0, blue: 0)
        let initialColor = RenderColor(
            source,
            renderingMode: settings.colorRendering,
            gamut: settings.colorGamut
        )
        let initialGamma = settings.textRendering.glyphGamma

        settings.textRendering = .crisp
        XCTAssertNotEqual(settings.textRendering.glyphGamma, initialGamma)
        XCTAssertEqual(
            RenderColor(source, renderingMode: settings.colorRendering, gamut: settings.colorGamut),
            initialColor
        )

        let crispGamma = settings.textRendering.glyphGamma
        settings.colorRendering = .vivid
        XCTAssertNotEqual(
            RenderColor(source, renderingMode: settings.colorRendering, gamut: settings.colorGamut),
            initialColor
        )
        XCTAssertEqual(settings.textRendering.glyphGamma, crispGamma)
    }

}
