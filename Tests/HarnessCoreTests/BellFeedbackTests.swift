import XCTest
@testable import HarnessCore

final class BellFeedbackTests: XCTestCase {
    // MARK: GUI mode (no tmux options set)

    func testGUIModeDrivesFeedbackWhenNoTmuxOptions() {
        XCTAssertEqual(BellFeedback.resolve(mode: .off), .init(audible: false, visual: false))
        XCTAssertEqual(BellFeedback.resolve(mode: .audible), .init(audible: true, visual: false))
        XCTAssertEqual(BellFeedback.resolve(mode: .visual), .init(audible: false, visual: true))
        XCTAssertEqual(BellFeedback.resolve(mode: .both), .init(audible: true, visual: true))
    }

    func testDefaultModeIsVisual() {
        // The shipped default: a focused bell flashes (was previously silent), no beep.
        XCTAssertEqual(HarnessSettings().bellMode, .visual)
    }

    // MARK: tmux `bell-action` gate

    func testBellActionOffSuppressesEverything() {
        // Even with a noisy GUI mode, `bell-action off`/`none` means no feedback.
        XCTAssertTrue(BellFeedback.resolve(mode: .both, bellAction: "off").isSilent)
        XCTAssertTrue(BellFeedback.resolve(mode: .both, bellAction: "none").isSilent)
        XCTAssertTrue(BellFeedback.resolve(mode: .audible, visualBell: "on", bellAction: "off").isSilent)
    }

    func testBellActionAnyOrOtherPassesThrough() {
        // Window-scoping actions don't change the audible/visual split (focus handles scope).
        XCTAssertEqual(BellFeedback.resolve(mode: .audible, bellAction: "any"), .init(audible: true, visual: false))
        XCTAssertEqual(BellFeedback.resolve(mode: .visual, bellAction: "other"), .init(audible: false, visual: true))
    }

    // MARK: tmux `visual-bell` override

    func testVisualBellOverridesGUIMode() {
        // `visual-bell on` forces visual even if the GUI mode is audible.
        XCTAssertEqual(BellFeedback.resolve(mode: .audible, visualBell: "on"), .init(audible: false, visual: true))
        // `visual-bell off` forces audible even if the GUI mode is visual.
        XCTAssertEqual(BellFeedback.resolve(mode: .visual, visualBell: "off"), .init(audible: true, visual: false))
        // `visual-bell both` → both channels.
        XCTAssertEqual(BellFeedback.resolve(mode: .off, visualBell: "both"), .init(audible: true, visual: true))
    }

    func testUnrecognizedVisualBellFallsThroughToGUIMode() {
        XCTAssertEqual(BellFeedback.resolve(mode: .visual, visualBell: "wat"), .init(audible: false, visual: true))
    }

    func testBellActionOffBeatsVisualBellOn() {
        // The gate (1) takes precedence over the override (2): no alerts at all.
        XCTAssertTrue(BellFeedback.resolve(mode: .visual, visualBell: "on", bellAction: "none").isSilent)
    }

    // MARK: Codable round-trip + migration

    func testBellModeSurvivesCodableRoundTrip() throws {
        var settings = HarnessSettings()
        settings.bellMode = .both
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: data)
        XCTAssertEqual(decoded.bellMode, .both)
    }

    func testLegacyConfigWithoutBellModeDecodesToDefault() throws {
        // An older settings.json with no `bellMode` key must decode to the default, not throw.
        let json = "{\"fontSize\": 13}"
        let decoded = try JSONDecoder().decode(HarnessSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bellMode, .visual)
    }
}
