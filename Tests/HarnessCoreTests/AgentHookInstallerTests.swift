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
        XCTAssertTrue(command.hasPrefix("PATH=\"$HOME/Library/Application Support/Harness/bin:$PATH\" harness-cli notify"))
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

    func testCodexInstallsEventHooksWithoutFeatureFlag() throws {
        let result = try AgentHookInstaller.install(agent: .codex, homeOverride: home)
        // hooks.json uses the event/matcher shape (not the inert on_pause/on_done keys).
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try Data(contentsOf: result.path)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        XCTAssertNil(hooks["on_pause"])
        XCTAssertNotNil(hooks["Stop"] as? [Any])
        XCTAssertNotNil(hooks["PermissionRequest"] as? [Any])
        XCTAssertNotNil(hooks["Notification"] as? [Any])
        // Codex hooks are enabled by default now — we must NOT write config.toml anymore.
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex/config.toml").path))
    }

    func testCursorInstallsStopHookArrayShape() throws {
        // Seed the user's own stop hook to prove it survives the merge.
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .cursor, homeOverride: home))
        XCTAssertTrue(url.path.hasSuffix(".cursor/hooks.json"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{ "version": 1, "hooks": { "stop": [ { "command": "echo mine" } ] } }"#
            .write(to: url, atomically: true, encoding: .utf8)

        func stopCommands() throws -> [String] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(json["version"] as? Int, 1)
            let stop = try XCTUnwrap((json["hooks"] as? [String: Any])?["stop"] as? [Any])
            return stop.compactMap { ($0 as? [String: Any])?["command"] as? String }
        }

        _ = try AgentHookInstaller.install(agent: .cursor, homeOverride: home)
        var commands = try stopCommands()
        XCTAssertTrue(commands.contains("echo mine"))
        XCTAssertEqual(commands.filter { $0.contains("harness-cli notify") }.count, 1)

        // Reinstall converges to exactly one Harness entry (prune works), user entry intact.
        _ = try AgentHookInstaller.install(agent: .cursor, homeOverride: home)
        commands = try stopCommands()
        XCTAssertTrue(commands.contains("echo mine"))
        XCTAssertEqual(commands.filter { $0.contains("harness-cli notify") }.count, 1)
    }

    func testGrokWritesOwnFlatFileAndLeavesSiblingsAlone() throws {
        let result = try AgentHookInstaller.install(agent: .grok, homeOverride: home)
        XCTAssertTrue(result.path.path.hasSuffix(".grok/hooks/harness.json"))
        // Grok merges every *.json in the dir — a sibling user file must be untouched.
        let sibling = result.path.deletingLastPathComponent().appendingPathComponent("user.json")
        try #"{"pre-edit":"echo hi"}"#.write(to: sibling, atomically: true, encoding: .utf8)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: result.path)) as? [String: Any])
        XCTAssertTrue((json["on-complete"] as? String)?.contains("harness-cli notify") ?? false)
        XCTAssertTrue((json["on-error"] as? String)?.contains("harness-cli notify") ?? false)
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .grok, homeOverride: home))

        let again = try AgentHookInstaller.install(agent: .grok, homeOverride: home)
        XCTAssertNotNil(again.backedUp) // our own file existed → backed up before overwrite
        XCTAssertEqual(try String(contentsOf: sibling, encoding: .utf8), #"{"pre-edit":"echo hi"}"#)
    }

    func testOpenCodeInstallsPluginFile() throws {
        XCTAssertTrue(AgentHookInstaller.canInstall(.openCode))
        let result = try AgentHookInstaller.install(agent: .openCode, homeOverride: home)
        XCTAssertTrue(result.path.path.hasSuffix(".config/opencode/plugins/harness.js"))
        let text = try String(contentsOf: result.path, encoding: .utf8)
        XCTAssertTrue(text.contains("session.idle"))
        XCTAssertTrue(text.contains("harness-cli notify"))
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .openCode, homeOverride: home))
        // Idempotent overwrite: reinstall backs up and reproduces the same plugin.
        let again = try AgentHookInstaller.install(agent: .openCode, homeOverride: home)
        XCTAssertNotNil(again.backedUp)
        XCTAssertEqual(try String(contentsOf: again.path, encoding: .utf8), text)
    }

    func testPiInstallsTsExtension() throws {
        let result = try AgentHookInstaller.install(agent: .pi, homeOverride: home)
        XCTAssertTrue(result.path.path.hasSuffix(".pi/agent/extensions/harness.ts"))
        let text = try String(contentsOf: result.path, encoding: .utf8)
        XCTAssertTrue(text.contains("harness-cli notify"))
        XCTAssertTrue(text.contains("session_end"))
        XCTAssertTrue(text.contains("HARNESS_SURFACE ?? \"\""))
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .pi, homeOverride: home))
    }

    func testHermesYamlEditPreservesContentAndIsIdempotent() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .hermes, homeOverride: home))
        XCTAssertTrue(url.path.hasSuffix(".hermes/config.yaml"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model: hermes-3\nprovider: nous\n".write(to: url, atomically: true, encoding: .utf8)

        _ = try AgentHookInstaller.install(agent: .hermes, homeOverride: home)
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("model: hermes-3"))   // user content preserved
        XCTAssertTrue(text.contains("harness-cli notify"))
        XCTAssertTrue(text.contains("harness-managed"))
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .hermes, homeOverride: home))

        // Reinstall replaces the managed region in place — not a second copy.
        _ = try AgentHookInstaller.install(agent: .hermes, homeOverride: home)
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "harness-cli notify").count - 1, 1)
    }

    func testOpenClawJson5EditPreservesComments() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .openClaw, homeOverride: home))
        XCTAssertTrue(url.path.hasSuffix(".openclaw/openclaw.json"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json5 = """
        {
          // user comment — must survive
          gateway: { port: 8080 },
        }
        """
        try json5.write(to: url, atomically: true, encoding: .utf8)

        _ = try AgentHookInstaller.install(agent: .openClaw, homeOverride: home)
        var text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("// user comment — must survive"), "JSON5 comments must not be destroyed")
        XCTAssertTrue(text.contains("gateway"))
        XCTAssertTrue(text.contains("harness-cli notify"))
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .openClaw, homeOverride: home))

        // Reinstall replaces the managed region in place — not a second copy.
        _ = try AgentHookInstaller.install(agent: .openClaw, homeOverride: home)
        text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "harness-cli notify").count - 1, 1)
    }

    func testHermesSkipsWhenConfigAlreadyDefinesHooks() throws {
        // A user who already has a top-level `hooks:` must not get a duplicate key (invalid YAML).
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .hermes, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "model: hermes-3\nhooks:\n  - event: lint\n    command: 'echo mine'\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let result = try AgentHookInstaller.install(agent: .hermes, homeOverride: home)
        XCTAssertTrue(result.needsManualMerge)
        XCTAssertFalse(AgentHookInstaller.isInstalled(agent: .hermes, homeOverride: home))
        // File left exactly as it was — no corruption, no second `hooks:`.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testOpenClawSkipsWhenConfigAlreadyDefinesHooks() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .openClaw, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "{\n  \"hooks\": { \"x\": 1 },\n}\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let result = try AgentHookInstaller.install(agent: .openClaw, homeOverride: home)
        XCTAssertTrue(result.needsManualMerge)
        XCTAssertFalse(AgentHookInstaller.isInstalled(agent: .openClaw, homeOverride: home))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testRegionEditSkipsTornSentinel() throws {
        // Only the begin marker survives (e.g. a manual edit) — refuse to guess; leave it alone.
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .hermes, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "model: hermes-3\n# >>> harness-managed (do not edit) >>>\nhooks:\n  - event: stop\n"
        try original.write(to: url, atomically: true, encoding: .utf8)

        let result = try AgentHookInstaller.install(agent: .hermes, homeOverride: home)
        XCTAssertTrue(result.needsManualMerge)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    func testFreshOpenClawInstallProducesWrappedObject() throws {
        // New user: no openclaw.json yet — install must create a valid JSON5 root object.
        let result = try AgentHookInstaller.install(agent: .openClaw, homeOverride: home)
        XCTAssertNil(result.backedUp)
        let text = try String(contentsOf: result.path, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("{"))
        XCTAssertTrue(text.contains("\"hooks\""))
        XCTAssertTrue(text.contains("harness-cli notify"))
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .openClaw, homeOverride: home))
    }

    func testFreshHermesInstallCreatesConfigYaml() throws {
        let result = try AgentHookInstaller.install(agent: .hermes, homeOverride: home)
        XCTAssertNil(result.backedUp)
        let text = try String(contentsOf: result.path, encoding: .utf8)
        XCTAssertTrue(text.contains("hooks:"))
        XCTAssertTrue(text.contains("harness-cli notify"))
        XCTAssertTrue(AgentHookInstaller.isInstalled(agent: .hermes, homeOverride: home))
    }

    func testLegacyOrphanRemovedWhenHarnessOwned() throws {
        // An older Harness wrote cursor hooks at the now-wrong `.cursor/agent-hooks.json`.
        let legacy = home.appendingPathComponent(".cursor/agent-hooks.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{ "agent_notify": "harness-cli notify --title Cursor" }"#.write(to: legacy, atomically: true, encoding: .utf8)

        let result = try AgentHookInstaller.install(agent: .cursor, homeOverride: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "Harness-owned orphan removed")
        XCTAssertEqual(result.removedLegacy, [legacy])
    }

    func testLegacyFilePreservedWhenUserOwned() throws {
        let legacy = home.appendingPathComponent(".cursor/agent-hooks.json")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{ "my_own": "echo not harness" }"#.write(to: legacy, atomically: true, encoding: .utf8)

        let result = try AgentHookInstaller.install(agent: .cursor, homeOverride: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path), "a non-Harness file at the old path is left alone")
        XCTAssertTrue(result.removedLegacy.isEmpty)
    }

    func testResolveAgentNameAliases() {
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("claude"), .claudeCode)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("claude-code"), .claudeCode)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("cursor-agent"), .cursor)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("codex"), .codex)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("grok"), .grok)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("grok-build"), .grok)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("opencode"), .openCode)
        XCTAssertNil(AgentHookInstaller.resolveAgentName("nonsense-agent"))
    }

    /// `installableAgents` (the curated, ordered list) and `canInstall` (derived from the
    /// strategy table) must never diverge — adding a strategy without listing the agent, or vice
    /// versa, is a bug.
    func testInstallableAgentsMatchStrategyCapability() {
        XCTAssertEqual(
            Set(AgentHookInstaller.installableAgents),
            Set(AgentKind.allCases.filter { AgentHookInstaller.canInstall($0) })
        )
    }

    /// A header comment containing a brace must not be mistaken for the JSON5 root object.
    func testOpenClawJson5InsertSkipsBraceInLeadingComment() throws {
        let url = try XCTUnwrap(AgentHookInstaller.hookConfigURL(for: .openClaw, homeOverride: home))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json5 = """
        // OpenClaw config — see docs at { example.com } for the schema
        {
          gateway: { port: 8080 },
        }
        """
        try json5.write(to: url, atomically: true, encoding: .utf8)

        _ = try AgentHookInstaller.install(agent: .openClaw, homeOverride: home)
        let text = try String(contentsOf: url, encoding: .utf8)
        // The managed region landed inside the real root object, after the header comment.
        let header = try XCTUnwrap(text.range(of: "see docs at"))
        let region = try XCTUnwrap(text.range(of: "harness-managed"))
        XCTAssertTrue(header.lowerBound < region.lowerBound, "region must come after the header comment")
        XCTAssertTrue(text.contains("harness-cli notify"))
        XCTAssertTrue(text.contains("gateway"))
    }

    func testSetupPromptCoversEveryInstallableAgentAndItsRealPath() {
        let prompt = AgentHookInstaller.setupPrompt
        XCTAssertTrue(prompt.contains("harness-cli notify"))
        XCTAssertTrue(prompt.contains("$HARNESS_SURFACE"))
        XCTAssertTrue(prompt.contains("install-hooks"))
        for kind in AgentHookInstaller.installableAgents {
            XCTAssertTrue(prompt.contains("install-hooks \(kind.rawValue)"),
                          "prompt should tell the IDE how to install \(kind.rawValue)")
            if let url = AgentHookInstaller.hookConfigURL(for: kind) {
                XCTAssertTrue(prompt.contains(url.lastPathComponent),
                              "prompt should cite \(kind.rawValue)'s config file \(url.lastPathComponent)")
            }
        }
    }

    func testGrokIsInstallableAndDetectable() {
        XCTAssertTrue(AgentHookInstaller.canInstall(.grok))
        XCTAssertTrue(AgentHookInstaller.installableAgents.contains(.grok))
        XCTAssertTrue(AgentTable.default.entries.contains { $0.kind == .grok && $0.executables.contains("grok") })
    }
}
