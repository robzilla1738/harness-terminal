import XCTest
@testable import HarnessCore

/// Roadmap PR-9: `set-option` now validates the option name (a typo like `moused` is rejected
/// loudly instead of silently persisted and never read), while `@`-prefixed user options are
/// always accepted and resolve in the format engine (`#{@name}`).
final class OptionValidationTests: XCTestCase {
    // MARK: - Key validation

    func testKnownBuiltinOptionsAreRecognized() {
        for key in ["status", "status-position", "mouse", "mode-keys", "history-limit", "remain-on-exit"] {
            XCTAssertTrue(OptionStore.isRecognizedOptionKey(key), "\(key) is a builtin default")
        }
    }

    func testReadButUnseededOptionsAreRecognized() {
        // synchronize-panes is implemented (written per-tab by the toggle) but unseeded — it must
        // not be rejected, or the GUI/compositor sync-panes toggle breaks.
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("synchronize-panes"))
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("status-center"))
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("status-format-0"))
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("status-format-12"))
        XCTAssertFalse(OptionStore.isRecognizedOptionKey("status-format-x"), "non-numeric suffix is not a row")
    }

    func testAliasAndCommonTmuxOptionsAreRecognized() {
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("default-terminal"), "tmux alias")
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("status-interval"), "recognized tmux option (compat)")
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("word-separators"))
    }

    func testUserOptionsAreAlwaysAccepted() {
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("@my_var"))
        XCTAssertTrue(OptionStore.isRecognizedOptionKey("@theme"))
        XCTAssertFalse(OptionStore.isRecognizedOptionKey("@"), "a bare @ names nothing")
    }

    func testUnknownOptionsAreRejected() {
        XCTAssertFalse(OptionStore.isRecognizedOptionKey("moused"), "the F50 example typo")
        XCTAssertFalse(OptionStore.isRecognizedOptionKey("bogus-option"))
        XCTAssertFalse(OptionStore.isRecognizedOptionKey("statuss"))
    }

    // MARK: - #{@name} format resolution

    private func context(userOptions: [String: String]) -> FormatContext {
        var c = FormatContext(sessionName: "work")
        c.userOptions = userOptions
        return c
    }

    func testUserOptionTokenResolves() {
        let ctx = context(userOptions: ["@theme": "dracula", "@count": "3"])
        XCTAssertEqual(FormatString.evaluate("#{@theme}", context: ctx), "dracula")
        XCTAssertEqual(FormatString.evaluate("theme=#{@theme} n=#{@count}", context: ctx), "theme=dracula n=3")
    }

    func testUnsetUserOptionRendersEmpty() {
        XCTAssertEqual(FormatString.evaluate("#{@nope}", context: context(userOptions: [:])), "")
    }

    func testUserOptionInConditionalTest() {
        let ctx = context(userOptions: ["@theme": "dracula"])
        XCTAssertEqual(FormatString.evaluate("#{?@theme,set,unset}", context: ctx), "set")
        XCTAssertEqual(FormatString.evaluate("#{?@missing,set,unset}", context: ctx), "unset")
    }
}
