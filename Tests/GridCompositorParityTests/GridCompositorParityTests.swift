import XCTest

// Drift canary for GridCompositor. The live compositor (HarnessTerminalKit) and its
// onboarding-preview port (HarnessOnboarding) are intentionally decoupled copies — the port
// inlines its model types, renames RenderCell → ComposedCell, and drops copy-mode. This test
// guards the SHARED subset they must keep identical: pane layout, box-drawing borders + junction
// glyphs, pane-border labels, and the status line. Each half builds the SAME documented fixture
// (CompositorFixtureSpec) through its own compositor (LiveCompositorFixture / PortCompositorFixture)
// and we assert the emitted ANSI is byte-for-byte identical.
//
// Copy-mode (selection / search overlays) is out of scope — the port never sets those fields, so
// the parity surface is the plain composition only. If a case here fails, the two
// GridCompositor.swift files have diverged on the shared subset; reconcile them.
final class GridCompositorParityTests: XCTestCase {
    func testTwoPaneSplitWithStatusComposesIdentically() {
        XCTAssertEqual(LiveCompositorFixture.twoPaneWithStatus(), PortCompositorFixture.twoPaneWithStatus(), """
        GridCompositor drift: the live (HarnessTerminalKit) and onboarding-port (HarnessOnboarding) \
        compositors produced different ANSI for the same 2-pane + border + status fixture. \
        Reconcile the shared rendering subset across both GridCompositor.swift files.
        """)
    }

    func testBorderJunctionComposesIdentically() {
        XCTAssertEqual(LiveCompositorFixture.borderJunction(), PortCompositorFixture.borderJunction(), """
        GridCompositor drift: live vs onboarding-port produced different ANSI for the \
        border-junction fixture — the box-glyph junction table has diverged.
        """)
    }

    /// Guard against a vacuous pass (both helpers returning the same empty/degenerate string):
    /// the composed frame must carry real content — a clear, box-drawing, and the status text.
    func testFixtureIsNonTrivial() {
        let frame = LiveCompositorFixture.twoPaneWithStatus()
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(frame.contains("\u{2502}"), "expected a vertical box-drawing border in the frame")
        XCTAssertTrue(frame.contains("left"), "expected the status text in the frame")
    }
}
