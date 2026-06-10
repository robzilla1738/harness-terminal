import XCTest
@testable import HarnessCore

/// Roadmap PR-16: the remaining high-frequency `.tmux.conf` format operators on top of PR-7's
/// nested-conditional fix — `!=`, `||`, `&&`, `n:` (length), `T:` (double-expand), `a:` (char from
/// code), `p<N>:` (pad).
final class FormatStringOperatorTests: XCTestCase {
    private func context() -> FormatContext {
        FormatContext(
            paneTitle: "fish",
            paneActive: true,
            sessionName: "work",
            tabName: "editor",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func eval(_ s: String, _ ctx: FormatContext? = nil) -> String {
        FormatString.evaluate(s, context: ctx ?? context())
    }

    func testNotEquals() {
        XCTAssertEqual(eval("#{!=:a,b}"), "1")
        XCTAssertEqual(eval("#{!=:a,a}"), "")
        // Composes with the conditional and nested tokens (the PR-7 capability).
        XCTAssertEqual(eval("#{?#{!=:#{session_name},play},Y,N}"), "Y")
    }

    func testLogicalOrAnd() {
        XCTAssertEqual(eval("#{||:,x}"), "1", "or is true when either side is non-empty")
        XCTAssertEqual(eval("#{||:,}"), "", "or is false when both sides are empty")
        XCTAssertEqual(eval("#{&&:x,y}"), "1", "and is true when both sides are non-empty")
        XCTAssertEqual(eval("#{&&:x,}"), "", "and is false when a side is empty")
        // Truthiness reads through token expansion.
        XCTAssertEqual(eval("#{&&:#{session_name},#{tab_name}}"), "1")
    }

    func testLength() {
        XCTAssertEqual(eval("#{n:hello}"), "5")
        XCTAssertEqual(eval("#{n:#{session_name}}"), "4") // "work"
        XCTAssertEqual(eval("#{n:}"), "0")
    }

    func testExpandTwice() {
        var ctx = context()
        ctx.userOptions = ["@fmt": "#{session_name}"] // a user-var whose VALUE is itself a format
        XCTAssertEqual(eval("#{@fmt}", ctx), "#{session_name}", "single expansion yields the format text")
        XCTAssertEqual(eval("#{T:#{@fmt}}", ctx), "work", "T: expands the resolved value a second time")
    }

    func testExpandTwiceWithSelfReferenceIsBoundedNotCrashing() {
        var ctx = context()
        // A user-var whose value re-invokes T: on itself: a naive double-expand recurses until
        // the daemon's stack overflows. The depth guard must terminate it (rendering empty),
        // never crash.
        ctx.userOptions = ["@loop": "#{T:#{@loop}}"]
        XCTAssertEqual(eval("#{T:#{@loop}}", ctx), "", "a self-referential T: expansion is bounded, not a stack overflow")
        // A non-recursive T: still works after the guard is in place.
        ctx.userOptions["@ok"] = "#{session_name}"
        XCTAssertEqual(eval("#{T:#{@ok}}", ctx), "work")
    }

    func testCharFromCode() {
        XCTAssertEqual(eval("#{a:65}"), "A")
        XCTAssertEqual(eval("#{a:35}"), "#")
        XCTAssertEqual(eval("#{a:}"), "", "no code → empty")
    }

    func testPad() {
        XCTAssertEqual(eval("#{p5:ab}"), "ab   ", "pads to width with trailing spaces")
        XCTAssertEqual(eval("#{p2:abcd}"), "abcd", "never truncates when already wider")
        XCTAssertEqual(eval("#{p4:#{session_name}}"), "work", "exact width is unchanged")
        // A token that merely starts with `p` is not a pad operator — it resolves normally.
        XCTAssertEqual(eval("#{pane_title}"), "fish")
    }
}
