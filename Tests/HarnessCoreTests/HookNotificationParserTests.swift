import XCTest
@testable import HarnessCore

/// Covers the stdin-JSON parser behind `harness-cli notify --from-hook`, which surfaces the
/// real Claude Code `Notification` message instead of the old (always-empty) env-var body.
final class HookNotificationParserTests: XCTestCase {
    private func data(_ string: String) -> Data { Data(string.utf8) }

    func testExtractsMessageAndCWDFromClaudeNotificationJSON() {
        let json = #"{"message":"Permission needed","cwd":"/Users/x/proj","hook_event_name":"Notification","session_id":"abc"}"#
        let parsed = HookNotificationParser.parse(data(json))
        XCTAssertEqual(parsed?.message, "Permission needed")
        XCTAssertEqual(parsed?.cwd, "/Users/x/proj")
    }

    func testEmptyAndInvalidInputReturnNil() {
        XCTAssertNil(HookNotificationParser.parse(Data()))
        XCTAssertNil(HookNotificationParser.parse(data("not json at all")))
        XCTAssertNil(HookNotificationParser.parse(data("[1,2,3]"))) // JSON, but not an object
    }

    func testMissingOrEmptyMessageIsNil() {
        let parsed = HookNotificationParser.parse(data(#"{"cwd":"/x","message":""}"#))
        XCTAssertNil(parsed?.message)
        XCTAssertEqual(parsed?.cwd, "/x")
    }

    func testResolveBodyPrefersMessageThenFallbackThenDefault() {
        let withMessage = HookNotificationParser.Parsed(message: "Hi", cwd: nil)
        XCTAssertEqual(HookNotificationParser.resolveBody(parsed: withMessage, fallbackBody: "Done"), "Hi")
        // No message → fall back to the CLI --body (lets the Stop hook keep saying "Done").
        let noMessage = HookNotificationParser.Parsed(message: nil, cwd: nil)
        XCTAssertEqual(HookNotificationParser.resolveBody(parsed: noMessage, fallbackBody: "Done"), "Done")
        // No message, no fallback, or nil parse → sensible default, never empty.
        XCTAssertEqual(HookNotificationParser.resolveBody(parsed: noMessage, fallbackBody: nil), "Needs attention")
        XCTAssertEqual(HookNotificationParser.resolveBody(parsed: nil, fallbackBody: ""), "Needs attention")
    }
}
