import XCTest
@testable import HarnessCore

final class CraftSliceTests: XCTestCase {
    func testMissingThemeFitFollowsAppearanceAndIgnoresReduceMotion() throws {
        let missing = try JSONDecoder().decode(HarnessSettings.self, from: Data("{}".utf8))
        XCTAssertNil(missing.themeFit)
        XCTAssertTrue(missing.effectiveThemeFit(appearanceIsLight: true, reduceMotion: false))
        XCTAssertTrue(missing.effectiveThemeFit(appearanceIsLight: true, reduceMotion: true))
        XCTAssertFalse(missing.effectiveThemeFit(appearanceIsLight: false, reduceMotion: false))
        XCTAssertFalse(missing.effectiveThemeFit(appearanceIsLight: false, reduceMotion: true))
        XCTAssertEqual(
            ThemeFitPolicy.enabled(stored: nil, appearanceIsLight: true, reduceMotion: true),
            ThemeFitPolicy.enabled(stored: nil, appearanceIsLight: true, reduceMotion: false)
        )

        let storedOff = try JSONDecoder().decode(HarnessSettings.self, from: Data(#"{"themeFit":false}"#.utf8))
        XCTAssertEqual(storedOff.themeFit, false)
        XCTAssertFalse(storedOff.effectiveThemeFit(appearanceIsLight: true, reduceMotion: false))
    }

    func testWindowAndPaletteWriteTheSameDecodedSettings() throws {
        var fromWindow = HarnessSettings()
        var fromPalette = HarnessSettings()
        SettingsEditor.applyFromWindow(\.pasteProtection, false, on: &fromWindow)
        SettingsEditor.applyFromPalette(\.pasteProtection, false, on: &fromPalette)
        SettingsEditor.applyFromWindow(\.paneDensity, .compact, on: &fromWindow)
        SettingsEditor.applyFromPalette(\.paneDensity, .compact, on: &fromPalette)

        let decodedWindow = try JSONDecoder().decode(HarnessSettings.self, from: JSONEncoder().encode(fromWindow))
        let decodedPalette = try JSONDecoder().decode(HarnessSettings.self, from: JSONEncoder().encode(fromPalette))
        XCTAssertEqual(decodedWindow, decodedPalette)
        XCTAssertFalse(decodedWindow.pasteProtection)
        XCTAssertEqual(decodedWindow.paneDensity, .compact)

        let appearanceIsLight = true
        var paletteToggle = HarnessSettings()
        let themeRow = try XCTUnwrap(SettingsPalette.rows(appearanceIsLight: appearanceIsLight).first { $0.id == "themeFit" })
        themeRow.apply(&paletteToggle)
        var windowToggle = HarnessSettings()
        SettingsEditor.applyFromWindow(
            \.themeFit,
            ThemeFitPolicy.stored(toggleOn: false, appearanceIsLight: appearanceIsLight),
            on: &windowToggle
        )
        XCTAssertEqual(paletteToggle.themeFit, windowToggle.themeFit)
        XCTAssertEqual(paletteToggle.themeFit, false)
    }

    func testPaletteRowsCoverEverySettingsWindowControl() {
        let ids = Set(SettingsPalette.rows(appearanceIsLight: false).map(\.id))
        let required = [
            "backgroundOpacity", "backgroundBlur", "windowBorderOpacity",
            "customBackgroundHex", "customForegroundHex", "customCursorHex", "cursorTextHex",
            "selectionBackgroundHex", "selectionForegroundHex", "boldColorHex",
            "dividerHex", "statusLineHex", "windowBorderHex", "paletteHex",
            "transparentTitlebar", "showStatusLine", "sidebarVisible", "restoreWindowSize",
            "windowPaddingX", "windowPaddingY", "appearanceMode",
            "fontSize", "fontFamily", "defaultShell", "defaultCWD",
            "scrollbackLines", "cursorStyle", "cursorBlink", "copyOnSelect",
            "systemNotificationsEnabled", "notificationSoundEnabled",
            "notchVisibilityMode", "notchOpenOnHover",
            "colorRendering", "textRendering",
            "applyThemeToTerminalOutput", "ligatures", "showPromptGutter",
            "offMainParserFramePipeline", "liveResizeReflow",
            "resizeOverlay", "resizeOverlayPosition", "bellMode",
            "scrollMultiplier", "mouseHideWhileTyping", "optionAsMeta",
            "quickTerminalEnabled", "quickTerminalHotkey", "windowPaddingBalance",
            "minimumContrast", "pasteProtection", "remoteControl", "boldIsBright",
            "themeFit", "paneDensity", "paneHeaders", "commandFinishedThresholdSeconds",
            "experienceMode", "prefixKeyEnabled", "statusLineEnabled", "prefixKey",
        ]
        for id in required {
            XCTAssertTrue(ids.contains(id), id)
        }
        for event in NotificationEvent.allCases {
            XCTAssertTrue(ids.contains("notify.\(event.rawValue)"))
        }
        for kind in AgentKind.allCases {
            XCTAssertTrue(ids.contains("agentColor.\(kind.rawValue)"))
        }
        XCTAssertTrue(DaemonSettingsControls.rows.contains { $0.key == "word-separators" })
    }

    func testDaemonSettingsCommandMatchesTheGlobalSetOption() {
        let command = DaemonSettingsControls.command(key: "word-separators", rawValue: " -_@")
        XCTAssertEqual(
            command,
            .setOption(scope: "global", target: nil, key: "word-separators", rawValue: " -_@")
        )
        guard case let .setOption(scope, target, key, rawValue) = DaemonSettingsControls.request(key: "word-separators", rawValue: " -_@") else {
            return XCTFail("expected a set-option request")
        }
        XCTAssertEqual(scope, "global")
        XCTAssertNil(target)
        XCTAssertEqual(key, "word-separators")
        XCTAssertEqual(rawValue, " -_@")
    }

    func testGhosttyImportIsNamedAndListsSkippedKeysIncludingFontSize() throws {
        XCTAssertEqual(TerminalConfigImporter.sourceName(for: ["/tmp/ghostty/config"]), "Ghostty")
        XCTAssertEqual(TerminalConfigImporter.sourceName(for: ["/tmp/config.ghostty"]), "Ghostty")
        XCTAssertEqual(
            TerminalConfigImporter.sourceName(for: ["/Users/x/Library/Application Support/com.mitchellh.ghostty/config"]),
            "Ghostty"
        )
        XCTAssertNil(TerminalConfigImporter.sourceName(for: ["/tmp/other/config"]))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-import-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("ghostty", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let config = dir.appendingPathComponent("config")
        try """
        font-family = Iosevka
        font-size = 17
        background = #111111
        not-a-harness-key = 1
        """.write(to: config, atomically: true, encoding: .utf8)

        let imported = try XCTUnwrap(TerminalConfigImporter.load(from: [config.path]))
        XCTAssertEqual(imported.sourceName, "Ghostty")
        XCTAssertEqual(imported.fontFamily, "Iosevka")
        XCTAssertEqual(imported.fontSize, 17)
        let settings = HarnessSettings.makeDefaults(imported: imported)
        XCTAssertEqual(settings.fontFamily, "Iosevka")
        XCTAssertEqual(settings.fontSize, 16)
        XCTAssertTrue(imported.skippedKeys.contains("font-size"))
        XCTAssertTrue(imported.skippedKeys.contains("not-a-harness-key"))
        XCTAssertFalse(imported.skippedKeys.contains("font-family"))
        XCTAssertTrue(imported.signature.hasPrefix("v7|"))
        XCTAssertFalse(imported.signature.contains("Ghostty"))
    }

    func testFindBarStaysAnOverlayAndMovesOffTheMatch() {
        XCTAssertFalse(FindBarNudge.changesRowCount)
        let match = FindBarNudge.Box(x: 560, y: 0, width: 240, height: 40)
        let placed = FindBarNudge.place(
            viewportWidth: 800,
            viewportHeight: 600,
            barWidth: 200,
            barHeight: 28,
            match: match
        )
        XCTAssertFalse(placed.intersects(match))
        XCTAssertGreaterThan(placed.y, match.maxY)

        let tallRight = FindBarNudge.Box(x: 500, y: 0, width: 300, height: 580)
        let leading = FindBarNudge.place(
            viewportWidth: 800,
            viewportHeight: 600,
            barWidth: 200,
            barHeight: 28,
            match: tallRight
        )
        XCTAssertEqual(leading.x, 10)
        XCTAssertEqual(leading.y, 8)
        XCTAssertFalse(leading.intersects(tallRight))
    }

    func testFailedCopyDoesNotFade() {
        XCTAssertTrue(CopyConfirmation.fadesSelection(pasteboardAccepted: true))
        XCTAssertFalse(CopyConfirmation.fadesSelection(pasteboardAccepted: false))
    }

    func testTabPeekKeepsTheLiveGridSize() {
        var peek = TabPeek(rows: 24, columns: 80, tabs: [
            TabPeek.Tab(id: "a", title: "a", preview: "one", mark: nil),
            TabPeek.Tab(id: "b", title: "b", preview: "two", mark: ProgramMark(
                attention: .blocked, kind: nil, message: nil, app: "codex", progress: nil, fromRealReport: true
            )),
        ])
        peek.toggle(reduceMotion: false)
        XCTAssertEqual(peek.phase, .peeking)
        peek.move(delta: 1)
        XCTAssertEqual(peek.selection, 1)
        peek.replaceTabs(peek.tabs + [TabPeek.Tab(id: "c", title: "c", preview: "", mark: nil)])
        peek.toggle(reduceMotion: false)
        XCTAssertEqual(peek.phase, .overview)
        XCTAssertEqual(peek.rows, 24)
        XCTAssertEqual(peek.columns, 80)

        var reduced = TabPeek(rows: 40, columns: 120, tabs: peek.tabs)
        reduced.toggle(reduceMotion: true)
        XCTAssertEqual(reduced.phase, .overview)
        XCTAssertEqual(reduced.rows, 40)
        XCTAssertEqual(reduced.columns, 120)
        XCTAssertEqual(TabPeek.badge(peek.tabs[1].mark), "blocked")
        XCTAssertEqual(TabPeek.badge(nil), "")
    }

    func testTabChipAppendsTheAppLabel() {
        XCTAssertEqual(TabChip.title(base: "zsh", app: nil), "zsh")
        XCTAssertEqual(TabChip.title(base: "zsh", app: ""), "zsh")
        XCTAssertEqual(TabChip.title(base: "zsh", app: "codex"), "zsh · codex")
    }
}
