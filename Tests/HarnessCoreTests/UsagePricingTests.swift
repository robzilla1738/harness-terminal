import Foundation
import HarnessCore
import XCTest

final class UsagePricingTests: XCTestCase {
    func testObservedModelsExplicitPricesAndProviderCacheAccounting() throws {
        let price = UsagePrice(model: "fixture-model", currency: "USD", input: 2, output: 10, cachedInput: 1, cacheCreation: 3)
        let counters = UsageCounters(input: 1_000_000, output: 100_000, cachedInput: 200_000, reasoning: 50_000, cacheCreation: 100_000)
        let codex = try UsagePricing.estimate(models: [price.model: counters], unknownModel: nil, provider: .codex, prices: [price])
        let claude = try UsagePricing.estimate(models: [price.model: counters], unknownModel: nil, provider: .claudeCode, prices: [price])
        XCTAssertEqual(codex.first?.amount, Decimal(string: "2.9"))
        XCTAssertEqual(claude.first?.amount, Decimal(string: "3.5"))
        XCTAssertEqual(codex.first?.incomplete, false)
        let partial = try UsagePricing.estimate(models: [price.model: counters, "unpriced": counters], unknownModel: UsageCounters(input: 1), provider: .codex, prices: [price])
        XCTAssertEqual(partial.first?.amount, codex.first?.amount)
        XCTAssertEqual(partial.first?.incomplete, true)
        XCTAssertEqual(partial.first?.unavailableModels, ["unpriced"])
        let otherCurrency = UsagePrice(model: "other", currency: "EUR", input: 1, output: 1)
        let separate = try UsagePricing.estimate(models: [price.model: counters, "other": counters], unknownModel: nil, provider: .claudeCode, prices: [price, otherCurrency])
        XCTAssertEqual(separate.map(\.currency), ["EUR", "USD"])
        XCTAssertThrowsError(try UsagePricing.estimate(models: [price.model: UsageCounters(input: 0, cachedInput: Int64.max, cacheCreation: Int64.max)], unknownModel: nil, provider: .codex, prices: [price]))
        XCTAssertThrowsError(try UsagePricing.estimate(models: [price.model: UsageCounters(output: -1)], unknownModel: nil, provider: .codex, prices: [price]))
        XCTAssertThrowsError(try UsagePricing.estimate(models: [:], unknownModel: nil, provider: .codex, prices: [price, price]))
    }
    func testTimelineDoesNotAttachAnOldEventToAReplacementShell() throws {
        var event = RunEvent(runID: UUID(), kind: .toolStarted, source: .hook, terminalSequence: 100, streamIdentity: "original")
        XCTAssertEqual(event.availability(stream: "original", firstSequence: 80, endSequence: 120, terminalPresent: true), .retained)
        XCTAssertEqual(event.availability(stream: "original", firstSequence: 101, endSequence: 120, terminalPresent: true), .evicted)
        XCTAssertEqual(event.availability(stream: "replacement", firstSequence: 1, endSequence: 120, terminalPresent: true), .streamReplaced)
        XCTAssertEqual(event.availability(stream: nil, firstSequence: nil, endSequence: nil, terminalPresent: false), .terminalClosed)
        event.streamIdentity = nil
        XCTAssertEqual(event.availability(stream: "original", firstSequence: 1, endSequence: 120, terminalPresent: true), .unavailable)
        let restored = try JSONDecoder().decode(RunEvent.self, from: JSONEncoder().encode(event))
        XCTAssertNil(restored.streamIdentity)
    }

}
