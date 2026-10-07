import XCTest
@testable import HarnessCore

final class ChromeSurfaceTests: XCTestCase {
    func testIdentityShowsDirectoryAndProgram() {
        let both = SurfaceIdentity.label(directory: "/Users/me/harness", program: "nvim")
        XCTAssertTrue(both.contains("harness"))
        XCTAssertTrue(both.contains("nvim"))
        XCTAssertTrue(both.contains("›"))

        // The login shell is the prompt, not a second path segment.
        let shellOnly = SurfaceIdentity.label(directory: "/Users/me/harness", program: "fish")
        XCTAssertEqual(shellOnly, "harness")
        XCTAssertFalse(shellOnly.contains("fish"))

        let missing = SurfaceIdentity.label(directory: "/Users/me/harness", program: nil)
        let blank = SurfaceIdentity.label(directory: "/Users/me/harness", program: "  ")
        XCTAssertEqual(missing, "harness")
        XCTAssertEqual(blank, missing)
        XCTAssertFalse(missing.contains("fish"))

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SurfaceIdentity.label(directory: home, program: "fish"), "~")

        XCTAssertEqual(
            SurfaceIdentity.label(directory: "/Users/me/harness", program: "2.1.291"),
            "harness"
        )
        XCTAssertEqual(
            SurfaceIdentity.label(directory: "/Users/me/harness", program: "2.1.291", agent: "claude"),
            "harness › claude"
        )
        XCTAssertNil(SurfaceIdentity.usableProgram("2.1.291"))
        XCTAssertEqual(SurfaceIdentity.usableProgram("claude"), "claude")

        let nested = SurfaceIdentity.label(directory: home + "/Code/harness", program: "nvim")
        XCTAssertTrue(nested.contains("~/Code/harness"))
        XCTAssertTrue(nested.contains("nvim"))
    }

    func testTiledSplitFillsTheLengthWithAndWithoutADivider() {
        let even = ChromeLayout.tiledSplit(length: 800, thickness: 0, ratio: 0.5)
        XCTAssertEqual(even.first, 400)
        XCTAssertEqual(even.secondOrigin, 400)
        XCTAssertEqual(even.second, 400)
        XCTAssertEqual(even.first + even.second, 800)

        let hairline = ChromeLayout.tiledSplit(length: 800, thickness: 1, ratio: 0.25)
        XCTAssertEqual(hairline.first, 199.75)
        XCTAssertEqual(hairline.secondOrigin, 200.75)
        XCTAssertEqual(hairline.second, 599.25)
        XCTAssertEqual(hairline.first + 1 + hairline.second, 800)

        let half = ChromeLayout.tiledSplit(length: 640, thickness: 0, ratio: .nan)
        XCTAssertEqual(half.first, 320)
        XCTAssertEqual(half.second, 320)
    }

    func testContrastFloorsHoldForDefaultDarkAndLightPalettes() {
        let dark = ChromePaletteSpec.resolve(backgroundHex: "#000000", foregroundHex: "#ffffff")
        XCTAssertTrue(dark.isDark)
        XCTAssertEqual(dark.surface.hex, "#000000")
        XCTAssertTrue(ChromeContrast.meetsText(dark.textPrimary, on: dark.surface))
        XCTAssertTrue(ChromeContrast.meetsPill(dark.activePillLabel, on: dark.activePillFill))
        XCTAssertGreaterThanOrEqual(dark.textPrimary.contrastRatio(against: dark.surface), ChromeContrast.textMinimum)
        XCTAssertGreaterThanOrEqual(
            dark.activePillLabel.contrastRatio(against: dark.activePillFill),
            ChromeContrast.pillMinimum
        )

        let light = ChromePaletteSpec.resolve(backgroundHex: "#eeeeee", foregroundHex: "#353535")
        XCTAssertFalse(light.isDark)
        XCTAssertLessThan(light.textPrimary.relativeLuminance, light.surface.relativeLuminance)
        XCTAssertTrue(ChromeContrast.meetsText(light.textPrimary, on: light.surface))
        XCTAssertTrue(ChromeContrast.meetsPill(light.activePillLabel, on: light.activePillFill))
    }

    func testLightPaintOpacityDoesNotRewriteTheStoredDefault() {
        let stored: Float = 0.63
        XCTAssertEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .theme, systemAppearance: .light),
            stored,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .theme, systemAppearance: .dark),
            stored,
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .light, systemAppearance: .dark),
            ChromeMaterial.lightPaintOpacityFloor
        )
        XCTAssertGreaterThanOrEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .light),
            ChromeMaterial.lightPaintOpacityFloor
        )
        XCTAssertEqual(
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .dark),
            stored,
            accuracy: 0.0001
        )
    }

    func testHeaderTintDoesNotStackOnTheMetalBackdrop() {
        let stored: Float = 0.63
        let themeHeader = ChromeMaterial.headerFillAlpha(stored: stored, appearanceMode: .theme, systemAppearance: .dark)
        let lightHeader = ChromeMaterial.headerFillAlpha(stored: stored, appearanceMode: .light, systemAppearance: .dark)
        XCTAssertEqual(themeHeader, ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .theme, systemAppearance: .dark), accuracy: 0.0001)
        XCTAssertEqual(themeHeader, stored, accuracy: 0.0001)
        XCTAssertEqual(
            lightHeader,
            ChromeMaterial.paintOpacity(stored: stored, appearanceMode: .light, systemAppearance: .dark),
            accuracy: 0.0001
        )
        XCTAssertGreaterThanOrEqual(lightHeader, ChromeMaterial.lightPaintOpacityFloor)
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .theme, systemAppearance: .dark))
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .light, systemAppearance: .dark))
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .theme, systemAppearance: .light))
        XCTAssertFalse(ChromeMaterial.headerFillIsClear(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .light))

        XCTAssertEqual(
            ChromeMaterial.backdropFillAlpha(stored: stored, appearanceMode: .theme, systemAppearance: .dark),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeMaterial.backdropFillAlpha(stored: stored, appearanceMode: .light, systemAppearance: .dark),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ChromeMaterial.backdropFillAlpha(stored: stored, appearanceMode: .macOSSystem, systemAppearance: .light),
            0,
            accuracy: 0.0001
        )
    }

    func testPillsHugLabelsAndComfortablePanesAreEvenlyInsetCards() {
        let hugged = ChromeLayout.huggedPillWidth(labelWidth: 90, accessoryWidth: 28, min: 72, max: 280)
        XCTAssertEqual(hugged, 118, accuracy: 0.001)
        XCTAssertLessThan(hugged, 280)
        let capped = ChromeLayout.huggedPillWidth(labelWidth: 400, accessoryWidth: 20, min: 72, max: 280)
        XCTAssertEqual(capped, 280, accuracy: 0.001)

        let flush = ChromeLayout.cardInsets(separated: false)
        XCTAssertEqual([flush.top, flush.leading, flush.bottom, flush.trailing], [0, 0, 0, 0])
        XCTAssertEqual(ChromeLayout.island(separated: false, splitRadius: 10).cornerRadius, 0)

        // Comfortable: edge gap == gap between panes == islandGap.
        let card = ChromeLayout.cardInsets(separated: true)
        let pad = ChromeLayout.containerPadding(separated: true)
        XCTAssertEqual(card.leading + pad.leading, ChromeLayout.islandGap, accuracy: 0.001)
        XCTAssertEqual(card.trailing + card.leading, ChromeLayout.islandGap, accuracy: 0.001)
        XCTAssertEqual(card.bottom + pad.bottom, ChromeLayout.islandGap, accuracy: 0.001)
        XCTAssertEqual(pad.top, 0, accuracy: 0.001)
        XCTAssertEqual(ChromeLayout.island(separated: true, splitRadius: 10).cornerRadius, 10)

        let widths = [80.0, 140.0, 100.0]
        XCTAssertEqual(ChromeLayout.slotOrigin(index: 1, widths: widths, spacing: 4), 84, accuracy: 0.001)
        XCTAssertEqual(ChromeLayout.slotOrigin(index: 2, widths: widths, spacing: 4), 228, accuracy: 0.001)
        XCTAssertEqual(ChromeLayout.dragTargetSlot(leadingX: 2, widths: widths, spacing: 4), 0)
        XCTAssertEqual(ChromeLayout.dragTargetSlot(leadingX: 82, widths: widths, spacing: 4), 1)
        XCTAssertEqual(ChromeLayout.dragTargetSlot(leadingX: 220, widths: widths, spacing: 4), 2)
    }

    func testLightAppearanceModeRoundTrips() throws {
        let settings = HarnessSettings(appearanceMode: .light)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: data)
        XCTAssertEqual(decoded.appearanceMode, .light)
        XCTAssertEqual(HarnessSettings().appearanceMode, .theme)
    }
}

final class TabDividerTests: XCTestCase {
    func testRulesSitOnlyBetweenInactiveUnhoveredNeighbours() {
        XCTAssertEqual(ChromeLayout.dividerSlots(count: 1, activeIndex: 0, hoveredIndex: nil), [])
        XCTAssertEqual(ChromeLayout.dividerSlots(count: 3, activeIndex: 2, hoveredIndex: nil), [0])
        XCTAssertEqual(ChromeLayout.dividerSlots(count: 4, activeIndex: 0, hoveredIndex: nil), [1, 2])
        XCTAssertEqual(ChromeLayout.dividerSlots(count: 5, activeIndex: 0, hoveredIndex: 3), [1])
        XCTAssertEqual(ChromeLayout.dividerSlots(count: 3, activeIndex: nil, hoveredIndex: nil), [0, 1])
    }
}

final class PaneIdentityTests: XCTestCase {
    func testSplitPanesKeepTheirOwnDirectoryAndCommand() {
        let left = PaneLeaf(cwd: "/src", command: "nvim")
        let right = PaneLeaf(cwd: "/logs", command: "claude")
        var tab = Tab(title: "t", cwd: "/src", rootPane: .branch(direction: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right)))
        tab.activePaneID = left.id
        XCTAssertEqual(PaneIdentity.of(leaf: left, in: tab), PaneIdentity(directory: "/src", program: "nvim", agent: nil))
        XCTAssertEqual(PaneIdentity.of(leaf: right, in: tab), PaneIdentity(directory: "/logs", program: "claude", agent: .claudeCode))
    }

    func testTabCwdFollowsTheFocusedPane() {
        let left = PaneLeaf()
        let right = PaneLeaf()
        var tab = Tab(title: "t", cwd: "/", rootPane: .branch(direction: .horizontal, ratio: 0.5, first: .leaf(left), second: .leaf(right)))
        tab.activePaneID = left.id
        let session = SessionGroup(tabs: [tab], activeTabID: tab.id)
        let workspace = Workspace(sessions: [session])
        var editor = SessionEditor(snapshot: SessionSnapshot(workspaces: [workspace], activeWorkspaceID: workspace.id))

        editor.updateTabCwd(surfaceID: right.surfaceID, path: "/right")
        XCTAssertEqual(editor.snapshot.workspaces[0].sessions[0].tabs[0].cwd, "/", "an unfocused pane doesn't move the tab")
        editor.updateTabCwd(surfaceID: left.surfaceID, path: "/left")
        XCTAssertEqual(editor.snapshot.workspaces[0].sessions[0].tabs[0].cwd, "/left")

        XCTAssertTrue(editor.setActivePane(workspaceID: workspace.id, tabID: tab.id, paneID: right.id))
        XCTAssertEqual(editor.snapshot.workspaces[0].sessions[0].tabs[0].cwd, "/right", "focus brings the pane's cwd")
        let leaves = editor.snapshot.workspaces[0].sessions[0].tabs[0].rootPane.allLeaves()
        XCTAssertEqual(leaves.map(\.cwd), ["/left", "/right"])
    }
}
