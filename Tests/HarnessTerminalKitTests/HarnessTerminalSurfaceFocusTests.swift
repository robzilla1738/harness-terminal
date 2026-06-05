import AppKit
import XCTest
@testable import HarnessTerminalKit

final class HarnessTerminalSurfaceFocusTests: XCTestCase {
    /// Clearing a pane's `.waiting` notification on focus hangs off `onBecameFocused`. It must
    /// fire when the surface becomes *effectively* focused — first responder × key window, the
    /// AppKit path a click-into / ⌘-Tab-back takes (not just the programmatic `focusTerminal()`
    /// used by tab switches) — and fire exactly once per transition (the `lastReportedFocus`
    /// guard), so the downstream daemon round-trip never fires on a no-op re-focus.
    @MainActor
    func testOnBecameFocusedFiresOncePerFocusInTransition() {
        let view = HarnessTerminalSurfaceView(offMainParserFramePipeline: true)
        var fires = 0
        view.onBecameFocused = { fires += 1 }

        // First responder alone, window not key → not effectively focused → no fire.
        _ = view.becomeFirstResponder()
        XCTAssertEqual(fires, 0, "first responder without a key window is not focus-in")

        // Window becomes key while first responder → effectively focused → fires once.
        view.testingSetWindowIsKey(true)
        XCTAssertEqual(fires, 1, "becoming effectively focused fires onBecameFocused")

        // Re-asserting the same state must not re-fire (lastReportedFocus guard).
        view.testingSetWindowIsKey(true)
        _ = view.becomeFirstResponder()
        XCTAssertEqual(fires, 1, "no transition → no extra fire")

        // Lose key (focus-out) then regain it (a second focus-in) → fires again, still once.
        view.testingSetWindowIsKey(false)
        XCTAssertEqual(fires, 1, "focus-out does not fire onBecameFocused")
        view.testingSetWindowIsKey(true)
        XCTAssertEqual(fires, 2, "the next focus-in fires again")
    }
}
