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

    func testResolveAgentNameAliases() {
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("claude"), .claudeCode)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("claude-code"), .claudeCode)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("cursor-agent"), .cursor)
        XCTAssertEqual(AgentHookInstaller.resolveAgentName("codex"), .codex)
        XCTAssertNil(AgentHookInstaller.resolveAgentName("nonsense-agent"))
    }
}
