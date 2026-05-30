import XCTest
@testable import HarnessCore

/// `PaneStyle`/`PaneStyleSet` parsing + the active/inactive base resolution that the GUI
/// and the ssh compositor both use for `window-style`/`pane-style` (dim inactive panes).
final class PaneStyleTests: XCTestCase {
    func testParsesFgBg() {
        let s = PaneStyle.parse("fg=colour245,bg=#262626")
        XCTAssertEqual(s.fg, .palette(245))
        XCTAssertEqual(s.bg, .rgb(r: 0x26, g: 0x26, b: 0x26))
    }

    func testParseIgnoresNonColorAttrsAndEmpty() {
        XCTAssertTrue(PaneStyle.parse("").isEmpty)
        let s = PaneStyle.parse("bold,fg=red,italics")
        XCTAssertEqual(s.fg, .palette(1))
        XCTAssertNil(s.bg)
    }

    func testParseDefaultIsExplicitNone() {
        // `default` parses to `.some(.none)` — distinct from "unset" (nil) so it can cancel a
        // more general style on the active pane.
        let s = PaneStyle.parse("fg=default")
        XCTAssertEqual(s.fg, .some(FormatColor.none))
    }

    func testInactivePaneUsesWindowStyle() {
        let set = PaneStyleSet(window: "fg=colour245,bg=colour235", windowActive: "", pane: "", paneActive: "")
        let base = set.base(active: false)
        XCTAssertEqual(base.fg, .palette(245))
        XCTAssertEqual(base.bg, .palette(235))
    }

    func testActivePaneFallsThroughToWindowStyleWhenNoActiveStyle() {
        // tmux: window-style alone dims *all* panes (active included).
        let set = PaneStyleSet(window: "bg=colour235", windowActive: "", pane: "", paneActive: "")
        XCTAssertEqual(set.base(active: true).bg, .palette(235))
    }

    func testActiveStyleDefaultCancelsDimOnActivePane() {
        // The canonical dim-inactive setup: window-style dims, window-active-style=default
        // restores the active pane to the surface default (no override).
        let set = PaneStyleSet(
            window: "fg=colour245,bg=colour235",
            windowActive: "fg=default,bg=default",
            pane: "", paneActive: ""
        )
        let active = set.base(active: true)
        XCTAssertNil(active.fg, "active pane should keep the theme default fg")
        XCTAssertNil(active.bg, "active pane should keep the theme default bg")
        let inactive = set.base(active: false)
        XCTAssertEqual(inactive.fg, .palette(245), "inactive pane stays dimmed")
        XCTAssertEqual(inactive.bg, .palette(235))
    }

    func testPaneStyleOverridesWindowStyle() {
        let set = PaneStyleSet(window: "bg=colour235", windowActive: "", pane: "bg=colour52", paneActive: "")
        XCTAssertEqual(set.base(active: false).bg, .palette(52), "pane-style overrides window-style")
    }

    func testEmptySetIsEmpty() {
        XCTAssertTrue(PaneStyleSet().isEmpty)
        XCTAssertTrue(PaneStyleSet(window: "", windowActive: "", pane: "", paneActive: "").base(active: false).fg == nil)
    }
}
