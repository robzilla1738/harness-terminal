import HarnessCore
import HarnessTerminalEngine
import HarnessTerminalRenderer
import HarnessTheme
@testable import HarnessTerminalKit
import XCTest

@MainActor
final class HarnessTerminalSurfaceColorTests: XCTestCase {
    func testOSCSystemPaletteDoesNotRecolorProgramANSIOutputWhenThemeOutputIsOff() throws {
        var systemPalette = Array(repeating: Optional<String>.none, count: 16)
        systemPalette[1] = "#112233"
        let (view, responses) = configuredSurface(
            outputPaletteHex: Array(repeating: nil, count: 16),
            oscPaletteHex: systemPalette
        )

        let sgrRed = try resolveCellColors(
            outputPaletteHex: Array(repeating: nil, count: 16),
            TerminalGridCell(codepoint: 0x41, foreground: .palette(1))
        ).foreground
        let sgrRedBackground = try resolveCellColors(
            outputPaletteHex: Array(repeating: nil, count: 16),
            TerminalGridCell(codepoint: 0x41, background: .palette(1))
        ).background
        XCTAssertEqual(sgrRed, RGBColor(hex: ThemeManager.defaultBaselinePaletteHex[1]))
        XCTAssertEqual(sgrRedBackground, RGBColor(hex: ThemeManager.defaultBaselinePaletteHex[1]))

        view.receive("\u{1b}]4;1;?\u{7}")

        XCTAssertEqual(responses.wrappedValue.last, "\u{1b}]4;1;rgb:1111/2222/3333\u{1b}\\")
    }


    func testResolvedSystemThemeOSCAnswersDoNotRecolorProgramANSIOutputWhenThemeOutputIsOff() throws {
        let resolved = ThemeManager.resolvedAppearance(
            themeName: "Harness Default",
            appearanceMode: .macOSSystem,
            systemAppearance: .dark,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Dracula",
            customBackgroundHex: nil,
            customForegroundHex: nil,
            customCursorHex: nil
        )
        let (view, responses) = configuredSurface(
            outputPaletteHex: Array(repeating: nil, count: 16),
            oscPaletteHex: resolved.paletteHex,
            canvasBackgroundHex: resolved.canvas.backgroundHex,
            canvasForegroundHex: resolved.canvas.foregroundHex,
            cursorHex: resolved.canvas.cursorHex
        )

        let sgrRed = try resolveCellColors(
            outputPaletteHex: Array(repeating: nil, count: 16),
            canvasBackgroundHex: resolved.canvas.backgroundHex,
            canvasForegroundHex: resolved.canvas.foregroundHex,
            TerminalGridCell(codepoint: 0x41, foreground: .palette(1))
        ).foreground
        XCTAssertEqual(sgrRed, RGBColor(hex: ThemeManager.defaultBaselinePaletteHex[1]))

        view.receive("\u{1b}]4;1;?\u{7}")

        XCTAssertEqual(responses.wrappedValue.last, "\u{1b}]4;1;rgb:ffff/5555/5555\u{1b}\\")
    }

    func testOSCSystemCanvasQueriesUseResolvedSystemColours() {
        var systemPalette = Array(repeating: Optional<String>.none, count: 16)
        systemPalette[4] = "#0000B6"
        let (view, responses) = configuredSurface(
            outputPaletteHex: Array(repeating: nil, count: 16),
            oscPaletteHex: systemPalette,
            canvasBackgroundHex: ThemeManager.systemLightBackgroundHex,
            canvasForegroundHex: ThemeManager.systemLightForegroundHex,
            cursorHex: ThemeManager.systemLightCursorHex
        )

        view.receive("\u{1b}]10;?\u{7}")
        view.receive("\u{1b}]11;?\u{7}")
        view.receive("\u{1b}]12;?\u{7}")
        view.receive("\u{1b}]4;4;?\u{7}")

        XCTAssertEqual(responses.wrappedValue, [
            "\u{1b}]10;rgb:1d1d/1d1d/1f1f\u{1b}\\",
            "\u{1b}]11;rgb:f5f5/f5f5/f7f7\u{1b}\\",
            "\u{1b}]12;rgb:0000/6666/cccc\u{1b}\\",
            "\u{1b}]4;4;rgb:0000/0000/b6b6\u{1b}\\",
        ])
    }

    func testANSIOutputUsesThemePaletteOnlyWhenThemeOutputIsOn() throws {
        var themedOutput = Array(repeating: Optional<String>.none, count: 16)
        themedOutput[1] = "#445566"

        let sgrRed = try resolveCellColors(
            outputPaletteHex: themedOutput,
            TerminalGridCell(codepoint: 0x41, foreground: .palette(1))
        ).foreground

        XCTAssertEqual(sgrRed, RGBColor(hex: "#445566"))
    }

    func testHostResetPropagationFeedsSystemCanvasAndOSCWithoutRecoloringANSIOutput() throws {
        let lightTheme = try XCTUnwrap(HarnessThemeCatalog.theme(named: "Zenwritten Light"))
        var settings = HarnessSettings(
            appearanceMode: .macOSSystem,
            systemLightThemeName: "Zenwritten Light",
            systemDarkThemeName: "Harness Default",
            customBackgroundHex: "#000000",
            customForegroundHex: "#111111",
            customCursorHex: "#222222",
            applyThemeToTerminalOutput: false
        )
        let stale = TerminalHostView.resolvedNativeAppearance(
            themeName: "Dracula",
            settings: settings,
            systemAppearance: .light
        )
        XCTAssertEqual(stale.canvasBackgroundHex, "#000000")

        settings.clearThemeColorOverrides()
        let resolved = TerminalHostView.resolvedNativeAppearance(
            themeName: "Dracula",
            settings: settings,
            systemAppearance: .light
        )
        XCTAssertEqual(resolved.canvasBackgroundHex, lightTheme.backgroundHex)
        XCTAssertEqual(resolved.canvasForegroundHex, lightTheme.foregroundHex)
        XCTAssertEqual(resolved.cursorHex, lightTheme.cursorHex ?? lightTheme.foregroundHex)
        XCTAssertEqual(resolved.outputPaletteHex, Array(repeating: nil, count: 16))
        XCTAssertEqual(resolved.oscPaletteHex, lightTheme.paletteHex)

        let (view, responses) = configuredSurface(
            outputPaletteHex: resolved.outputPaletteHex,
            oscPaletteHex: resolved.oscPaletteHex,
            canvasBackgroundHex: resolved.canvasBackgroundHex,
            canvasForegroundHex: resolved.canvasForegroundHex,
            cursorHex: resolved.cursorHex
        )

        let sgrRed = try resolveCellColors(
            outputPaletteHex: resolved.outputPaletteHex,
            canvasBackgroundHex: resolved.canvasBackgroundHex,
            canvasForegroundHex: resolved.canvasForegroundHex,
            TerminalGridCell(codepoint: 0x41, foreground: .palette(1))
        ).foreground
        XCTAssertEqual(sgrRed, RGBColor(hex: ThemeManager.defaultBaselinePaletteHex[1]))

        view.receive("\u{1b}]10;?\u{7}")
        view.receive("\u{1b}]11;?\u{7}")
        view.receive("\u{1b}]12;?\u{7}")
        view.receive("\u{1b}]4;1;?\u{7}")

        XCTAssertEqual(responses.wrappedValue, [
            oscColorResponse("10", hex: lightTheme.foregroundHex),
            oscColorResponse("11", hex: lightTheme.backgroundHex),
            oscColorResponse("12", hex: lightTheme.cursorHex ?? lightTheme.foregroundHex),
            oscColorResponse("4;1", hex: try XCTUnwrap(lightTheme.paletteHex[1])),
        ])
    }

    private func configuredSurface(
        outputPaletteHex: [String?],
        oscPaletteHex: [String?]?,
        canvasBackgroundHex: String = "#F5F5F7",
        canvasForegroundHex: String = "#1D1D1F",
        cursorHex: String = "#0066CC"
    ) -> (HarnessTerminalSurfaceView, Box<[String]>) {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: false)
        let responses = Box<[String]>([])
        view.onInput = { data in
            responses.wrappedValue.append(String(decoding: data, as: UTF8.self))
        }
        view.configureAppearance(
            fontFamily: "Menlo",
            fontSize: 14,
            vivid: false,
            colorRendering: .accurate,
            colorGamut: .auto,
            canvasBackgroundHex: canvasBackgroundHex,
            canvasForegroundHex: canvasForegroundHex,
            cursorHex: cursorHex,
            outputPaletteHex: outputPaletteHex,
            oscPaletteHex: oscPaletteHex,
            canvasOpacity: 1,
            cursorStyle: "block",
            cursorBlink: true,
            paddingX: 0,
            paddingY: 0,
            selectionBackgroundHex: nil,
            selectionForegroundHex: nil,
            copyOnSelect: false,
            scrollbackLines: 10_000,
            linearBlending: false,
            textRendering: .native,
            ligatures: true,
            promptGutter: false,
            offMainParserFramePipeline: false
        )
        return (view, responses)
    }

    private func resolveCellColors(
        outputPaletteHex: [String?],
        canvasBackgroundHex: String = "#F5F5F7",
        canvasForegroundHex: String = "#1D1D1F",
        _ cell: TerminalGridCell
    ) throws -> ResolvedCellColors {
        let normalizedOutputPalette = HarnessSettings.normalizedPalette(outputPaletteHex)
        let palette = try (0 ..< 16).map { index in
            try XCTUnwrap(RGBColor(hex: normalizedOutputPalette[index] ?? ThemeManager.defaultBaselinePaletteHex[index]))
        }
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: palette),
            defaultForeground: try XCTUnwrap(RGBColor(hex: canvasForegroundHex)),
            defaultBackground: try XCTUnwrap(RGBColor(hex: canvasBackgroundHex))
        )
        return resolver.resolve(cell)
    }

    private func oscColorResponse(_ selector: String, hex: String) -> String {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let red = cleaned.prefix(2)
        let greenStart = cleaned.index(cleaned.startIndex, offsetBy: 2)
        let blueStart = cleaned.index(cleaned.startIndex, offsetBy: 4)
        let green = cleaned[greenStart ..< blueStart]
        let blue = cleaned[blueStart ..< cleaned.endIndex]
        return "\u{1b}]\(selector);rgb:\(red)\(red)/\(green)\(green)/\(blue)\(blue)\u{1b}\\".lowercased()
    }
}

private final class Box<Value> {
    var wrappedValue: Value

    init(_ wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
