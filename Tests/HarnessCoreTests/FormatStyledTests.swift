import XCTest
@testable import HarnessCore

/// Phase 4: `#[…]` style spans, the styled-segment intermediate, and the format operators.
final class FormatStyledTests: XCTestCase {
    private var ctx: FormatContext {
        FormatContext(paneTitle: "editor", paneActive: true, sessionName: "api", now: Date(timeIntervalSince1970: 0))
    }

    // MARK: Plain-path regression

    func testPlainInputIsUnchanged() {
        // No `#[…]` → identical to the pre-styling output (single default segment).
        let s = "sess:#{session_name} #{?pane_active,on,off}"
        XCTAssertEqual(FormatString.evaluate(s, context: ctx), "sess:api on")
        let segs = FormatString.evaluateStyled(s, context: ctx)
        XCTAssertEqual(segs.count, 1)
        XCTAssertNil(segs[0].fg)
        XCTAssertEqual(segs[0].text, "sess:api on")
    }

    // MARK: Style spans

    func testStyleSpansSplitSegments() {
        let segs = FormatString.evaluateStyled("#[fg=red,bold]A#[bg=#2200ff]B#[default]C", context: ctx)
        XCTAssertEqual(segs.map(\.text), ["A", "B", "C"])
        XCTAssertEqual(segs[0].fg, .palette(1))
        XCTAssertTrue(segs[0].bold)
        XCTAssertEqual(segs[1].fg, .palette(1))           // fg carries over
        XCTAssertEqual(segs[1].bg, .rgb(r: 0x22, g: 0x00, b: 0xff))
        XCTAssertNil(segs[2].fg)                           // #[default] reset
        XCTAssertFalse(segs[2].bold)
    }

    func testEvaluateDropsStyleDirectives() {
        XCTAssertEqual(FormatString.evaluate("#[fg=green]ok#[default]", context: ctx), "ok")
    }

    func testColourIndexAndNames() {
        let segs = FormatString.evaluateStyled("#[fg=colour200]x", context: ctx)
        XCTAssertEqual(segs[0].fg, .palette(200))
    }

    // MARK: Operators

    func testEqualityOperator() {
        XCTAssertEqual(FormatString.evaluate("#{==:#{session_name},api}", context: ctx), "1")
        XCTAssertEqual(FormatString.evaluate("#{==:#{session_name},nope}", context: ctx), "")
    }

    func testMatchOperator() {
        XCTAssertEqual(FormatString.evaluate("#{m:ed.*,#{pane_title}}", context: ctx), "1")
        XCTAssertEqual(FormatString.evaluate("#{m:^zsh$,#{pane_title}}", context: ctx), "")
    }

    func testSubstituteOperator() {
        XCTAssertEqual(FormatString.evaluate("#{s/e/E/:#{pane_title}}", context: ctx), "Editor")
        // case-insensitive flag
        XCTAssertEqual(FormatString.evaluate("#{s/E/x/i:#{pane_title}}", context: ctx), "xditor")
    }

    func testMathOperator() {
        XCTAssertEqual(FormatString.evaluate("#{e|+|2|3}", context: ctx), "5")
        XCTAssertEqual(FormatString.evaluate("#{e|*|4|5}", context: ctx), "20")
        XCTAssertEqual(FormatString.evaluate("#{e|/|7|2}", context: ctx), "3.5")
    }

    func testInvalidRegexDegradesGracefully() {
        // An unparseable pattern must not throw — match → "", substitute → unchanged string.
        XCTAssertEqual(FormatString.evaluate("#{m:(,abc}", context: ctx), "")
        XCTAssertEqual(FormatString.evaluate("#{s/(/x/:abc}", context: ctx), "abc")
    }
}
