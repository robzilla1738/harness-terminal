import Foundation

public struct UsagePrice: Codable, Equatable, Sendable {
    public var model: String
    public var currency: String
    public var units: String
    public var input: Decimal
    public var output: Decimal
    public var cachedInput: Decimal?
    public var cacheCreation: Decimal?
    public init(model: String, currency: String, input: Decimal, output: Decimal, cachedInput: Decimal? = nil, cacheCreation: Decimal? = nil) {
        self.model = model; self.currency = currency; units = "per_million_tokens"
        self.input = input; self.output = output; self.cachedInput = cachedInput; self.cacheCreation = cacheCreation
    }
    public func validate() throws {
        let rates = [input, output] + [cachedInput, cacheCreation].compactMap { $0 }
        guard !model.isEmpty, model.utf8.count <= 512, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              units == "per_million_tokens", Locale.commonISOCurrencyCodes.contains(currency),
              rates.allSatisfy({ !$0.isNaN && $0 >= 0 && $0 <= 1_000_000 }) else { throw UsagePricingError.invalid }
    }
}
public struct UsageCost: Codable, Equatable, Sendable {
    public var amount: Decimal
    public var currency: String
    public var units = "explicit prices per million tokens"
    public var incomplete: Bool
    public var unavailableModels: [String]
    public init(amount: Decimal, currency: String, incomplete: Bool, unavailableModels: [String]) {
        self.amount = amount; self.currency = currency; self.incomplete = incomplete; self.unavailableModels = unavailableModels
    }
}
public enum UsagePricing {
    /// An observed model and an explicit price are required. Cached tokens are
    /// separate in Claude records and included in Codex's input total. Reasoning
    /// tokens are already included in output totals and are never billed twice here.
    public static func estimate(models: [String: UsageCounters], unknownModel: UsageCounters?, provider: AgentKind, prices: [UsagePrice]) throws -> [UsageCost] {
        guard prices.count <= 64 else { throw UsagePricingError.invalid }
        for price in prices { try price.validate() }
        guard Set(prices.map(\.model)).count == prices.count else { throw UsagePricingError.invalid }
        guard !prices.isEmpty, !models.isEmpty || unknownModel != nil else { return [] }
        let configured = Dictionary(uniqueKeysWithValues: prices.map { ($0.model, $0) })
        var totals: [String: Decimal] = [:], incomplete = unknownModel != nil, missing: Set<String> = []
        for (model, counters) in models {
            guard let price = configured[model] else { missing.insert(model); incomplete = true; continue }
            guard [counters.input, counters.output, counters.cachedInput, counters.cacheCreation, counters.reasoning].compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw UsagePricingError.invalid }
            var amount: Decimal = 0
            if let input = counters.input {
                if counters.cachedInput == nil || counters.cacheCreation == nil { incomplete = true }
                let cached = counters.cachedInput ?? 0, creation = counters.cacheCreation ?? 0
                let ordinary: Int64
                if provider == .codex {
                    let (uncached, firstOverflow) = input.subtractingReportingOverflow(cached)
                    let (remaining, secondOverflow) = uncached.subtractingReportingOverflow(creation)
                    guard !firstOverflow, !secondOverflow, remaining >= 0 else { throw UsagePricingError.invalid }
                    ordinary = remaining
                } else { ordinary = input }
                amount += Decimal(ordinary) * price.input / 1_000_000
                for (tokens, rate) in [(cached, price.cachedInput), (creation, price.cacheCreation)] where tokens > 0 {
                    if let rate { amount += Decimal(tokens) * rate / 1_000_000 } else { incomplete = true }
                }
            } else { incomplete = true }
            if let output = counters.output { amount += Decimal(output) * price.output / 1_000_000 } else { incomplete = true }
            totals[price.currency, default: 0] += amount
            guard !totals[price.currency]!.isNaN else { throw UsagePricingError.invalid }
        }
        return totals.keys.sorted().map { UsageCost(amount: totals[$0]!, currency: $0, incomplete: incomplete, unavailableModels: missing.sorted()) }
    }
}
public enum UsagePricingError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? { "Pricing needs unique observed model IDs, ISO currency codes, per_million_tokens units, and finite nonnegative rates. Cached input is included in Codex input totals and separate for Claude; reasoning is included in output totals." }
}
