import XCTest
@testable import HarnessCore

/// Regression coverage for the JSON deep-merge behind the agent hook installer. The
/// installer folds hooks into the agent's *own* config (e.g. ~/.claude/settings.json),
/// so the merge must never clobber the user's existing keys — only union its entries in.
final class JSONMergeTests: XCTestCase {
    func testPreservesUnrelatedExistingKeys() {
        let existing: [String: Any] = [
            "model": "claude-opus",
            "permissions": ["allow": ["Bash"]],
        ]
        let addition: [String: Any] = ["hooks": ["Stop": [["type": "command"]]]]
        let merged = JSONMerge.deepMerge(existing, addition)
        XCTAssertEqual(merged["model"] as? String, "claude-opus")
        XCTAssertEqual((merged["permissions"] as? [String: Any])?["allow"] as? [String], ["Bash"])
        XCTAssertNotNil(merged["hooks"])
    }

    func testMergesNestedHookEventsWithoutDroppingExistingEntries() {
        let userEntry: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": "user-thing"]]]
        let existing: [String: Any] = ["hooks": ["Notification": [userEntry]]]
        let harnessEntry: [String: Any] = ["matcher": "*", "hooks": [["type": "command", "command": "harness-cli notify"]]]
        let addition: [String: Any] = ["hooks": ["Notification": [harnessEntry], "Stop": [harnessEntry]]]

        let merged = JSONMerge.deepMerge(existing, addition)
        let hooks = merged["hooks"] as? [String: Any]
        let notification = hooks?["Notification"] as? [Any]
        // The user's existing Notification entry survives AND ours is appended.
        XCTAssertEqual(notification?.count, 2)
        XCTAssertNotNil(hooks?["Stop"])
    }

    func testIsIdempotent() {
        let existing: [String: Any] = ["hooks": ["Stop": [["type": "command", "command": "harness-cli notify"]]]]
        let addition = existing
        let once = JSONMerge.deepMerge(existing, addition)
        let twice = JSONMerge.deepMerge(once, addition)
        let stopOnce = (once["hooks"] as? [String: Any])?["Stop"] as? [Any]
        let stopTwice = (twice["hooks"] as? [String: Any])?["Stop"] as? [Any]
        // Re-running install-hooks must not duplicate identical entries.
        XCTAssertEqual(stopOnce?.count, 1)
        XCTAssertEqual(stopTwice?.count, 1)
    }

    func testScalarAdditionWins() {
        let existing: [String: Any] = ["version": 1, "agent_notify": "old"]
        let addition: [String: Any] = ["version": 1, "agent_notify": "new"]
        let merged = JSONMerge.deepMerge(existing, addition)
        XCTAssertEqual(merged["agent_notify"] as? String, "new")
    }
}
