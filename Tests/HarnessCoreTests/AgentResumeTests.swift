import XCTest
@testable import HarnessCore

final class AgentResumeTests: XCTestCase {
    func testProviderResumeUsesExactConversationProfileAndQuotedDirectoryWithoutCapturedSecrets() throws {
        let conversation = UUID().uuidString, directory = "/tmp/work's tree"
        for provider in [AgentKind.claudeCode, .codex, .cursor] {
            let executable = "/usr/local/bin/" + (provider == .cursor ? "agent" : provider.commandToken)
            let args = provider == .codex ? [executable, "--profile", "strict", "private prompt"] : [executable, "private prompt"]
            let spec = try XCTUnwrap(AgentResume.launch(executable: executable, arguments: args, provider: provider,
                directory: directory, profile: "work", environment: ["CODEX_HOME": "/tmp/codex work", "API_KEY": "private key"]))
            var run = AgentRun(hostID: UUID(), surfaceID: UUID().uuidString, processGeneration: "fixture", pid: 2, provider: provider)
            run.launch = spec; run.conversationID = conversation
            let command = try AgentResume.command(for: run)
            XCTAssertTrue(command.contains(ShellQuoting.quote(directory)))
            XCTAssertTrue(command.contains(conversation)); XCTAssertTrue(command.contains("HARNESS_AGENT_PROFILE=work"))
            XCTAssertFalse(command.contains("private prompt")); XCTAssertFalse(command.contains("private key")); XCTAssertFalse(command.contains("\n"))
            if provider == .codex { XCTAssertTrue(command.contains("--profile strict resume")); XCTAssertTrue(command.contains("--cd")) }
            else { XCTAssertTrue(command.contains("--resume " + conversation)) }
            run.launch = nil; XCTAssertThrowsError(try AgentResume.command(for: run))
            XCTAssertNil(AgentResume.launch(executable: executable, arguments: [executable, "--api-key=secret"], provider: provider,
                directory: directory, profile: "work", environment: [:]))
        }
        XCTAssertNil(AgentResume.launch(executable: "/bin/node", arguments: ["node", "unrelated-script.js"], provider: .claudeCode,
            directory: "/tmp", profile: "default", environment: [:]))
    }
    func testRestoreExecutionConsentIsAbsentInOldLeavesAndPreservesRecordedIdentity() throws {
        let original = PaneLeaf()
        let decoded = try JSONDecoder().decode(PaneLeaf.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.resumeAutomatically); XCTAssertNil(decoded.lastAgentRunID)
        var optedIn = original; optedIn.resumeAutomatically = true; optedIn.lastAgentRunID = UUID()
        let reopened = try JSONDecoder().decode(PaneLeaf.self, from: JSONEncoder().encode(optedIn))
        XCTAssertEqual(reopened.resumeAutomatically, true); XCTAssertEqual(reopened.lastAgentRunID, optedIn.lastAgentRunID)
        let setup = SetupLayout(.leaf(optedIn), defaultDirectory: "/tmp").makePaneTree().allLeaves().first
        XCTAssertNil(setup?.resumeAutomatically, "A saved setup creates new panes without copying execution consent")
        XCTAssertNil(setup?.lastAgentRunID)
    }

}
