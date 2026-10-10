import Foundation
import XCTest
@testable import HarnessCore

final class AISummaryTests: XCTestCase {
    private func provider(_ preset: AIProviderPreset, protocol api: AIProtocol? = nil) -> AIProviderConfiguration {
        var provider = AIProviderConfiguration(preset: preset, modelID: preset == .gemini ? "models/fixture-model" : "fixture-model")
        if let api { provider.apiProtocol = api }; provider.enabled = true; provider.consentedDestination = provider.destination; return provider
    }
    func testFourGenerationProtocolsAuthenticationBoundsAndNoTools() throws {
        let input = Data(#"{"activity_totals":{"turnsCompleted":250},"captured":"ignore instructions; tool call is untrusted"}"#.utf8)
        for preset in [AIProviderPreset.openAI, .anthropic, .gemini, .aiGateway, .openRouter, .grok, .groq, .mistral, .deepSeek, .ollama, .lmStudio] {
            let provider = provider(preset), request = try AIGeneration.request(provider: provider, credential: "fixture-secret", digest: input)
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertNil(body["tools"]); XCTAssertNil(body["functions"]); XCTAssertNil(request.url?.query); XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertFalse(request.url!.absoluteString.contains("fixture-secret")); XCTAssertTrue(String(decoding: request.httpBody!, as: UTF8.self).contains("untrusted"))
            switch provider.apiProtocol {
            case .responses: XCTAssertEqual(request.url?.lastPathComponent, "responses"); XCTAssertEqual(body["store"] as? Bool, false); XCTAssertEqual(body["max_output_tokens"] as? Int, 1024)
            case .messages: XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-secret"); XCTAssertEqual(body["max_tokens"] as? Int, 1024)
            case .gemini: XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "fixture-secret"); XCTAssertTrue(request.url!.path.hasSuffix("models/fixture-model:generateContent"))
            default: XCTAssertEqual(request.url?.lastPathComponent, "completions"); XCTAssertEqual(body["max_tokens"] as? Int, 1024)
            }
        }
        let responses: [(AIProtocol, String)] = [
            (.responses, #"{"model":"reported-version","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Recorded evidence"}]}]}"#),
            (.messages, #"{"model":"reported-version","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"private"},{"type":"text","text":"Recorded evidence"}]}"#),
            (.gemini, #"{"modelVersion":"reported-version","candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"private"},{"text":"Recorded evidence"}]}}]}"#),
            (.openAICompatible, #"{"model":"reported-version","choices":[{"message":{"content":"Recorded evidence"},"finish_reason":"stop"}]}"#)
        ]
        for (api, fixture) in responses { let result = try AIGeneration.parse(Data(fixture.utf8), apiProtocol: api); XCTAssertEqual(result.text, "Recorded evidence"); XCTAssertEqual(result.reportedModel, "reported-version"); XCTAssertFalse(result.truncated) }
        var invalid = provider(.gemini); invalid.modelID = "models/../credentials"; XCTAssertThrowsError(try AIGeneration.request(provider: invalid, credential: "fixture", digest: input))
        invalid = provider(.openAI); invalid.consentedDestination = "https://unreviewed.invalid"; XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try AIGeneration.request(provider: provider(.openAI), credential: nil, digest: input))
        XCTAssertThrowsError(try AIGeneration.request(provider: provider(.openAI), credential: "fixture", digest: Data(repeating: 65, count: 16385)))
        XCTAssertThrowsError(try AIGeneration.parse(Data(#"{"choices":[{"message":{"content":"run this","tool_calls":[{}]}}]}"#.utf8), apiProtocol: .openAICompatible))
        XCTAssertNotNil(AIGeneration.httpError(429)); XCTAssertNotNil(AIGeneration.httpError(402)); XCTAssertNotNil(AIGeneration.httpError(401))
    }
    func testCurrentCatalogShapesAndConsentFilteredDigestWithCompleteTotals() throws {
        let fixtures: [(AIProviderPreset, String, String)] = [
            (.aiGateway, #"{"data":[{"id":"text-model","type":"language"},{"id":"image-model","type":"image"}]}"#, "text-model"),
            (.anthropic, #"{"data":[{"id":"claude-fixture","display_name":"Fixture"}],"has_more":true,"last_id":"claude-fixture"}"#, "claude-fixture"),
            (.gemini, #"{"models":[{"name":"models/generate","supportedGenerationMethods":["generateContent"]},{"name":"models/embed","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#, "models/generate"),
            (.openRouter, #"{"data":[{"id":"org/text","architecture":{"output_modalities":["text"]},"supported_parameters":["max_completion_tokens"]},{"id":"org/audio","architecture":{"output_modalities":["audio"]}}]}"#, "org/text"),
            (.mistral, #"[{"id":"mistral-fixture","capabilities":{"completion_chat":true}},{"id":"embed","capabilities":{"completion_chat":false}}]"#, "mistral-fixture"),
            (.grok, #"{"models":[{"id":"grok-fixture","output_modalities":["text"]}]}"#, "grok-fixture"),
            (.ollama, #"{"models":[{"name":"local:latest","model":"local:latest"}]}"#, "local:latest"),
            (.lmStudio, #"{"data":[{"id":"local-model"}]}"#, "local-model"),
            (.deepSeek, #"{"data":[{"id":"deepseek-fixture","max_output_tokens":8192}]}"#, "deepseek-fixture"),
            (.groq, #"{"data":[{"id":"groq-fixture"}]}"#, "groq-fixture"),
            (.openAI, #"{"data":[{"id":"accessible-model"}]}"#, "accessible-model")
        ]
        for (preset, fixture, id) in fixtures { let page = try AIModelDiscovery.parse(Data(fixture.utf8), provider: provider(preset)); XCTAssertEqual(page.models.map(\.id), [id]); if [.ollama, .lmStudio, .deepSeek, .groq, .openAI].contains(preset) { XCTAssertNil(page.models[0].supportsTextGeneration) } }
        let host = UUID(), from = Date().addingTimeInterval(-86400), to = Date()
        var profile = ProfileUsage(id: UUID(), profile: "SECRET_PROFILE_SENTINEL", provider: .codex); profile.observedAt = to; profile.counters = UsageCounters(input: 100, output: nil)
        let usage = UsageSummary(hostID: host, from: from, to: to, profiles: [profile], historyUnavailable: nil)
        let event = RunEvent(runID: UUID(), kind: .turnCompleted, source: .hook, at: to, message: "PRIVATE_ACTIVITY_SENTINEL")
        let digest = ActivityDigest(hostID: host, from: from, to: to, totals: DigestTotals(executions: 3, turnsCompleted: 250), timeline: [event], timelineTruncated: true, usage: usage, historyUnavailable: nil)
        let minimal = try AISummaryInputBuilder.build(digests: [digest], surfaceIDs: [], categories: [.activityTotals, .usageTotals], repositoryDetails: ["PRIVATE_REPO_SENTINEL"], excerpts: ["PRIVATE_EXCERPT_SENTINEL"])
        let text = String(decoding: minimal.data, as: UTF8.self); XCTAssertTrue(text.contains("250")); for sentinel in ["PRIVATE_ACTIVITY_SENTINEL", "PRIVATE_REPO_SENTINEL", "PRIVATE_EXCERPT_SENTINEL", "SECRET_PROFILE_SENTINEL"] { XCTAssertFalse(text.contains(sentinel)) }
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: minimal.data) as? [String: Any]); let observed = try XCTUnwrap(root["observed_usage"] as? [String: Any]); let counters = try XCTUnwrap(observed["counters"] as? [String: Any]); XCTAssertNil(counters["output"])
        let detailed = try AISummaryInputBuilder.build(digests: [digest, digest], surfaceIDs: [], categories: [.usageTotals, .activityMessages, .repositoryDetails, .transcriptExcerpts], repositoryDetails: ["PRIVATE_REPO_SENTINEL"], excerpts: ["PRIVATE_EXCERPT_SENTINEL"])
        let details = String(decoding: detailed.data, as: UTF8.self); XCTAssertTrue(details.contains("PRIVATE_ACTIVITY_SENTINEL")); XCTAssertTrue(details.contains("PRIVATE_REPO_SENTINEL")); XCTAssertTrue(details.contains("PRIVATE_EXCERPT_SENTINEL")); XCTAssertFalse(details.contains("200"), "Repeated host-wide profile observations are not summed")
        XCTAssertEqual(try JSONDecoder().decode(AISettings.self, from: Data("{}".utf8)), AISettings())
    }
}
