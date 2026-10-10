import Foundation
import XCTest
@testable import HarnessCore

final class HookPolicyTests: XCTestCase {
    func testLiteralDecisionsProviderResponsesAndUnsupportedEnforcement() throws {
        let condition = HookPolicyCondition(field: .command, match: .contains, value: "fixture-protected")
        let ask = HookPolicyRule(event: "PreToolUse", conditions: [condition], decision: .ask, reason: "Review fixture operation")
        let deny = HookPolicyRule(event: "PreToolUse", conditions: [condition], decision: .deny, reason: "Fixture operation blocked")
        let policy = HookPolicy(name: "Fixture", contract: .claude202610, enabled: true, rules: [ask, deny])
        let payload = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"printf fixture-protected SECRET_INPUT_SENTINEL"},"cwd":"/fixture/private"}"#.utf8)
        let result = try HookPolicyEvaluator.evaluate(policy, data: payload, expectedEvent: "PreToolUse")
        XCTAssertEqual(result.decision, .deny); XCTAssertEqual(Set(result.matchedRules), [ask.id, deny.id])
        let response = String(decoding: try HookPolicyEvaluator.response(result, contract: .claude202610, event: "PreToolUse"), as: UTF8.self)
        XCTAssertTrue(response.contains("permissionDecision")); XCTAssertFalse(response.contains("SECRET_INPUT_SENTINEL")); XCTAssertFalse(response.contains("\u{1b}"))
        var asking = policy; asking.rules = [ask]; XCTAssertEqual(try HookPolicyEvaluator.evaluate(asking, data: payload, expectedEvent: "PreToolUse").decision, .ask)
        let unmatched = Data(#"{"hook_event_name":"PreToolUse","tool_input":{"command":"printf harmless"}}"#.utf8)
        XCTAssertEqual(try HookPolicyEvaluator.evaluate(policy, data: unmatched, expectedEvent: "PreToolUse").decision, .unchanged)
        XCTAssertThrowsError(try HookPolicyEvaluator.evaluate(policy, data: payload, expectedEvent: "Stop"))
        var codex = policy; codex.contract = .codex202610; codex.rules = [deny]; XCTAssertThrowsError(try codex.validate()); codex.enabled = false; try codex.validate()
        XCTAssertThrowsError(try HookPolicyInstallation.prepare(policy: codex, executable: URL(fileURLWithPath: "/fixture/harness-cli")))
        var cursor = asking; cursor.contract = .cursorV1; cursor.rules[0].event = "preToolUse"; XCTAssertThrowsError(try cursor.validate())
        cursor.rules[0].event = "beforeShellExecution"; try cursor.validate()
        let shell = Data(#"{"hook_event_name":"beforeShellExecution","command":"fixture-protected"}"#.utf8)
        XCTAssertEqual(try HookPolicyEvaluator.evaluate(cursor, data: shell, expectedEvent: "beforeShellExecution").decision, .ask)
        let audit = try JSONEncoder().encode(HookPolicyAudit(policyID: policy.id, contract: policy.contract, event: "PreToolUse", result: result, surfaceID: nil))
        XCTAssertFalse(String(decoding: audit, as: UTF8.self).contains("SECRET_INPUT_SENTINEL")); XCTAssertFalse(String(decoding: audit, as: UTF8.self).contains("/fixture/private"))
    }
    func testReviewedInstallationPreservesConfigurationAndAtomicBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hpolicy-" + UUID().uuidString); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let policy = HookPolicy(name: "Fixture", contract: .claude202610, enabled: true, rules: [HookPolicyRule(event: "PreToolUse", conditions: [HookPolicyCondition(field: .tool, match: .equals, value: "Bash")], decision: .ask, reason: "Review fixture")])
        let config = root.appendingPathComponent(".claude/settings.json"), original = Data(#"{"unknown":{"keep":true},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"user-fixture-hook"}]}]}}"#.utf8)
        _ = try PrivateFile.replace(config, data: original, expected: nil)
        let executable = URL(fileURLWithPath: "/fixture dir/harness-cli")
        XCTAssertThrowsError(try HookPolicyInstallation.prepare(policy: policy, executable: executable, home: root, providerVersion: "2.1.294 (Claude Code)"))
        let preview = try HookPolicyInstallation.prepare(policy: policy, executable: executable, home: root, providerVersion: "2.1.300 (Claude Code)")
        XCTAssertEqual(try PrivateFile.read(config), original, "Preview writes nothing")
        XCTAssertTrue(preview.diff.contains("onFailure")); XCTAssertFalse(preview.diff.contains("unknown"))
        let backup = try XCTUnwrap(HookPolicyInstallation.apply(preview)); XCTAssertEqual(try PrivateFile.read(backup), original)
        let updated = try XCTUnwrap(PrivateFile.read(config)); XCTAssertTrue(String(decoding: updated, as: UTF8.self).contains("user-fixture-hook")); XCTAssertTrue(String(decoding: updated, as: UTF8.self).contains("unknown"))
        let repeated = try HookPolicyInstallation.prepare(policy: policy, executable: executable, home: root, providerVersion: "2.1.300"); XCTAssertEqual(repeated.after, updated)
        let remove = try HookPolicyInstallation.prepare(policy: policy, executable: executable, home: root, remove: true); _ = try HookPolicyInstallation.apply(remove)
        let removed = String(decoding: try XCTUnwrap(PrivateFile.read(config)), as: UTF8.self); XCTAssertTrue(removed.contains("user-fixture-hook")); XCTAssertFalse(removed.contains("--harness-policy="))
        let registry = root.appendingPathComponent("trusted.json"); try HookPolicyRegistry.approve(policy, at: registry); XCTAssertTrue(try HookPolicyRegistry.load(at: registry)[0].policy.enabled)
        try HookPolicyRegistry.disable(policy.id, at: registry); XCTAssertFalse(try HookPolicyRegistry.load(at: registry)[0].policy.enabled)
    }
}
