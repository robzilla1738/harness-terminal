import XCTest
import HarnessCore

final class ProviderHookAdapterTests: XCTestCase {
    func testProviderTurnAndToolIdentitiesStaySeparateFromExecutionLifetime() throws {
        let fixtures: [(HookContract, String, String)] = [
            (.claude202610, #"{"hook_event_name":"Stop","session_id":"conversation","prompt_id":"turn"}"#, "turn"),
            (.codex202610, #"{"hook_event_name":"Stop","session_id":"conversation","turn_id":"turn"}"#, "turn"),
            (.cursorV1, #"{"hook_event_name":"stop","conversation_id":"conversation","generation_id":"generation"}"#, "generation"),
        ]
        for (contract, json, turn) in fixtures {
            let observation = try ProviderHookAdapter.parse(Data(json.utf8), contract: contract)
            XCTAssertEqual(observation.conversationID, "conversation")
            XCTAssertEqual(observation.turnID, turn)
            var run = AgentRun(hostID: UUID(), surfaceID: UUID().uuidString, processGeneration: "pid:start", pid: 12, provider: contract.provider, at: observation.reportedAt)
            AgentRunReducer.apply(RunEvent(runID: run.id, kind: observation.kind, source: .hook, at: observation.reportedAt), to: &run)
            XCTAssertEqual(run.turn, .completed); XCTAssertEqual(run.process, .running); XCTAssertNil(run.endedAt)
        }
        let tool = try ProviderHookAdapter.parse(Data(#"{"hook_event_name":"PreToolUse","session_id":"conversation","turn_id":"turn","tool_use_id":"tool","tool_name":"Bash","tool_input":{"command":"swift test"},"user_email":"ignored"}"#.utf8), contract: .codex202610)
        XCTAssertEqual(tool.kind, .toolStarted); XCTAssertEqual(tool.toolID, "tool"); XCTAssertEqual(tool.command, "swift test")
        XCTAssertThrowsError(try ProviderHookAdapter.parse(Data(#"{"hook_event_name":"unknownFutureEvent"}"#.utf8), contract: .codex202610))
        XCTAssertThrowsError(try ProviderHookAdapter.parse(Data(repeating: 65, count: ProviderHookAdapter.maximumPayloadBytes + 1), contract: .codex202610))
    }
}
