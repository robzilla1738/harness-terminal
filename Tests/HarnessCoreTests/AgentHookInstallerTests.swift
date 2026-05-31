import XCTest
@testable import HarnessCore

/// Covers the shared (HarnessCore) hook installer used by both `harness-cli install-hooks`
/// and the Settings "Install hooks" button. All tests run against a temp `homeOverride` so
/// they never touch the real `~/.claude` etc.
final class AgentHookInstallerTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testInstallCreatesFileAndIsDetected() throws {
        XCTAssertFalse(AgentHookInstaller.isInstalled(agent: .claudeCode, homeOverride: home))
        let result = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path.path))
        XCTAssertNil(result.backedUp)
        XCTAssertFalse(result.replacedInvalidJSON)
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .claudeCode, homeOverride: home))
        let text = try String(contentsOf: result.path, encoding: .utf8)
        XCTAssertTrue(text.contains("harness-cli notify"))
    }

    func testInstallPreservesExistingUserConfig() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .claudeCode, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = #"{ "model": "claude-opus", "permissions": { "allow": ["Bash"] } }"#
        try existing.write(to: url, atomically: true, encoding: .utf8)

        let result = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)
        XCTAssertNotNil(result.backedUp) // backed the user's file up
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-opus")
        XCTAssertNotNil(json["hooks"]) // ours merged in
        XCTAssertNotNil((json["permissions"] as? [String: Any])?["allow"])
    }

    func testReinstallIsIdempotent() throws {
        _ = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)
        let again = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)
        XCTAssertNotNil(again.backedUp)
        let data = try Data(contentsOf: again.path)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = json["hooks"] as? [String: Any]
        let notification = hooks?["Notification"] as? [Any]
        XCTAssertEqual(notification?.count, 1) // not duplicated on reinstall
    }

    func testClaudeNotificationUsesStdinHookNotEnvVar() throws {
        let result = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)
        let command = try claudeNotificationCommand(at: result.path)
        XCTAssertTrue(command.contains("--from-hook"), "Notification body must come from stdin")
        XCTAssertFalse(command.contains("HARNESS_NOTIFY_MESSAGE"), "the dangling env var must be gone")
    }

    /// The migration: a config carrying the OLD broken `$HARNESS_NOTIFY_MESSAGE` hook must
    /// converge to exactly one corrected entry on (re)install — not append a second copy.
    func testInstallUpgradesOldBrokenNotificationHookInPlace() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .claudeCode, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let broken = #"""
        {
          "model": "claude-opus",
          "permissions": { "allow": ["Bash"] },
          "hooks": {
            "Notification": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Claude Code\" --body \"$HARNESS_NOTIFY_MESSAGE\"" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo my-own-hook" } ] }
            ]
          }
        }
        """#
        try broken.write(to: url, atomically: true, encoding: .utf8)

        _ = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let notification = try XCTUnwrap(hooks["Notification"] as? [Any])
        XCTAssertEqual(notification.count, 1, "old broken entry replaced, not appended")
        let command = try claudeNotificationCommand(at: url)
        XCTAssertTrue(command.contains("--from-hook"))
        XCTAssertFalse(command.contains("HARNESS_NOTIFY_MESSAGE"))
        // Unrelated config + the user's own non-Harness hook survive untouched.
        XCTAssertEqual(json["model"] as? String, "claude-opus")
        XCTAssertNotNil((json["permissions"] as? [String: Any])?["allow"])
        XCTAssertNotNil(hooks["PreToolUse"] as? [Any])
    }

    /// A user's *own* Notification entry (no Harness marker) must be preserved alongside ours.
    func testInstallPreservesUserNotificationEntries() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .claudeCode, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = #"""
        { "hooks": { "Notification": [
          { "matcher": "*", "hooks": [ { "type": "command", "command": "say hello" } ] }
        ] } }
        """#
        try existing.write(to: url, atomically: true, encoding: .utf8)

        _ = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let notification = try XCTUnwrap((json["hooks"] as? [String: Any])?["Notification"] as? [Any])
        XCTAssertEqual(notification.count, 2, "the user's entry plus exactly one Harness entry")
        let commands = notification.compactMap { entry -> String? in
            ((entry as? [String: Any])?["hooks"] as? [Any])?
                .compactMap { ($0 as? [String: Any])?["command"] as? String }.first
        }
        XCTAssertTrue(commands.contains("say hello"))
        XCTAssertTrue(commands.contains { $0.contains("--from-hook") })
    }

    func testReinstallStaysSingleAndCorrected() throws {
        _ = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)
        _ = try AgentHookInstaller.install(agent: .claudeCode, homeOverride: home)
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .claudeCode, homeOverride: home))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let notification = try XCTUnwrap((json["hooks"] as? [String: Any])?["Notification"] as? [Any])
        XCTAssertEqual(notification.count, 1)
        XCTAssertTrue(try claudeNotificationCommand(at: url).contains("--from-hook"))
    }

    func testDetectInstalledAgentsFindsAgentByConfigDir() throws {
        // Inject a table whose executables can't exist on PATH, so the result is driven purely
        // by config-dir presence — deterministic regardless of what's installed on the host.
        let table = AgentTable(entries: AgentKind.allCases.map {
            AgentTableEntry(kind: $0, executables: ["harness-test-\(UUID().uuidString)"])
        })
        // A bare `~/.claude` dir (no binary needed) signals Claude Code is set up here.
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let detected = AgentHookInstaller.detectInstalledAgents(homeOverride: home, table: table)
        XCTAssertEqual(detected, [.claudeCode], "only the agent with a config dir is offered")
    }

    /// Helper: pull the single Harness `Notification` command string out of a Claude config.
    private func claudeNotificationCommand(at url: URL) throws -> String {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let notification = try XCTUnwrap(hooks["Notification"] as? [Any])
        let harness = notification.compactMap { entry -> String? in
            ((entry as? [String: Any])?["hooks"] as? [Any])?
                .compactMap { ($0 as? [String: Any])?["command"] as? String }
                .first { $0.contains("harness-cli notify") }
        }
        return try XCTUnwrap(harness.first)
    }

    func testInvalidExistingJSONIsReplacedWithBackup() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .codex, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)

        let result = try AgentHookInstaller.install(agent: .codex, homeOverride: home)
        XCTAssertTrue(result.replacedInvalidJSON)
        XCTAssertNotNil(result.backedUp)
        // The written file is now valid JSON with our hook.
        let data = try Data(contentsOf: url)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .codex, homeOverride: home))
    }

    func testUnsupportedAgentThrows() {
        XCTAssertThrowsError(try AgentHookInstaller.install(agent: .aider, homeOverride: home)) { error in
            XCTAssertEqual(error as? AgentHookInstaller.InstallError, .unsupported(.aider))
        }
        XCTAssertFalse(AgentHookInstaller.canInstall(.gemini))
        XCTAssertNil(AgentHookInstaller.hookConfigURL(for: .goose, homeOverride: home))
    }

    func testCodexInstallsEventHooksAndEnablesFeatureFlag() throws {
        let result = try AgentHookInstaller.install(agent: .codex, homeOverride: home)
        // hooks.json uses the event/matcher shape (not the inert on_pause/on_done keys).
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: result.path)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNil(hooks["on_pause"])
        XCTAssertNotNil(hooks["Stop"] as? [Any])
        XCTAssertNotNil(hooks["PermissionRequest"] as? [Any])
        // config.toml gained [features] hooks = true so Codex actually loads the hooks.
        let toml = try String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("[features]"))
        XCTAssertTrue(toml.contains("hooks = true"))
    }

    func testCodexFeatureFlagMergesIntoExistingConfig() throws {
        let toml = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: toml.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"o3\"\n\n[features]\nweb_search = true\n".write(to: toml, atomically: true, encoding: .utf8)

        _ = try AgentHookInstaller.install(agent: .codex, homeOverride: home)
        let content = try String(contentsOf: toml, encoding: .utf8)
        XCTAssertTrue(content.contains("model = \"o3\""))      // preserved
        XCTAssertTrue(content.contains("web_search = true"))    // preserved
        XCTAssertTrue(content.contains("hooks = true"))         // added inside [features]
        // Idempotent: a reinstall doesn't duplicate the flag.
        _ = try AgentHookInstaller.install(agent: .codex, homeOverride: home)
        let again = try String(contentsOf: toml, encoding: .utf8)
        XCTAssertEqual(again.components(separatedBy: "hooks = true").count - 1, 1)
    }

    func testOpenCodeIsDetectedButNotInstallable() {
        // OpenCode notifies via process detection, not a hook file.
        XCTAssertFalse(AgentHookInstaller.canInstall(.openCode))
        XCTAssertNil(AgentHookInstaller.hookConfigURL(for: .openCode, homeOverride: home))
        XCTAssertTrue(AgentTable.default.entries.contains { $0.kind == .openCode && $0.executables.contains("opencode") })
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("opencode"), .openCode)
    }

    func testResolveAgentNameAliases() {
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("claude"), .claudeCode)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("claude-code"), .claudeCode)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("cursor-agent"), .cursor)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("codex"), .codex)
        XCTAssertNil(AgentHookInstaller.resolveAgentName("nonsense-agent"))
    }
}
