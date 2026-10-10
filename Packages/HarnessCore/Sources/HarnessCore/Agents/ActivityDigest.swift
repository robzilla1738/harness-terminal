import Foundation

public struct ObservedLimit: Codable, Equatable, Sendable {
    public var window: String
    public var usedPercent: Double
    public var windowMinutes: Int?
    public var predictedReset: Date?
    public var observedAt: Date
    /// A provider reported a later reset boundary and lower usage after the old boundary.
    /// Passing a predicted time alone never populates this field.
    public var resetObservedAt: Date?
    public init(window: String, usedPercent: Double, windowMinutes: Int?, predictedReset: Date?, observedAt: Date) {
        self.window = window; self.usedPercent = usedPercent; self.windowMinutes = windowMinutes
        self.predictedReset = predictedReset; self.observedAt = observedAt
    }
}
public struct ProfileUsage: Codable, Sendable, Identifiable {
    public var id: UUID
    public var profile: String
    public var provider: AgentKind
    public var counters: UsageCounters
    public var limits: [ObservedLimit]
    public var observedAt: Date?
    public var unavailable: String?
    public var coverageWarnings: [String]?
    public var costs: [UsageCost]?
    public init(id: UUID, profile: String, provider: AgentKind, counters: UsageCounters = UsageCounters(), limits: [ObservedLimit] = [], observedAt: Date? = nil, unavailable: String? = nil) {
        self.id = id; self.profile = profile; self.provider = provider; self.counters = counters
        self.limits = limits; self.observedAt = observedAt; self.unavailable = unavailable
    }
}
public struct UsageSummary: Codable, Sendable {
    public var hostID: UUID
    public var from: Date
    public var to: Date
    public var profiles: [ProfileUsage]
    public var historyUnavailable: String?
    public init(hostID: UUID, from: Date, to: Date, profiles: [ProfileUsage], historyUnavailable: String?) {
        self.hostID = hostID; self.from = from; self.to = to; self.profiles = profiles; self.historyUnavailable = historyUnavailable
    }
}
public struct DigestTotals: Codable, Sendable {
    public var executions: Int
    public var turnsCompleted: Int
    public var turnsFailed: Int
    public var toolsStarted: Int
    public var toolsCompleted: Int
    public init(executions: Int = 0, turnsCompleted: Int = 0, turnsFailed: Int = 0, toolsStarted: Int = 0, toolsCompleted: Int = 0) {
        self.executions = executions; self.turnsCompleted = turnsCompleted; self.turnsFailed = turnsFailed
        self.toolsStarted = toolsStarted; self.toolsCompleted = toolsCompleted
    }
}
public extension DigestTotals {
    static func recorded(executions: Int, eventCounts: [String: Int]) -> DigestTotals {
        DigestTotals(executions: executions, turnsCompleted: eventCounts[RunEventKind.turnCompleted.rawValue] ?? 0,
            turnsFailed: eventCounts[RunEventKind.turnFailed.rawValue] ?? 0, toolsStarted: eventCounts[RunEventKind.toolStarted.rawValue] ?? 0,
            toolsCompleted: eventCounts[RunEventKind.toolCompleted.rawValue] ?? 0)
    }
    mutating func add(_ other: DigestTotals) throws {
        func sum(_ a: Int, _ b: Int) throws -> Int { let (total, overflow) = a.addingReportingOverflow(b); guard !overflow else { throw UsageAccountingError.invalid }; return total }
        executions = try sum(executions, other.executions); turnsCompleted = try sum(turnsCompleted, other.turnsCompleted)
        turnsFailed = try sum(turnsFailed, other.turnsFailed); toolsStarted = try sum(toolsStarted, other.toolsStarted); toolsCompleted = try sum(toolsCompleted, other.toolsCompleted)
    }
}
public struct ActivityDigest: Codable, Sendable {
    public var hostID: UUID
    public var from: Date
    public var to: Date
    public var totals: DigestTotals
    public var tests: TestExecutionSummary?
    public var timeline: [RunEvent]
    public var timelineTruncated: Bool
    public var usage: UsageSummary
    public var historyUnavailable: String?
    public init(hostID: UUID, from: Date, to: Date, totals: DigestTotals, timeline: [RunEvent], timelineTruncated: Bool, usage: UsageSummary, historyUnavailable: String?) {
        self.hostID = hostID; self.from = from; self.to = to; self.totals = totals; self.timeline = timeline
        self.timelineTruncated = timelineTruncated; self.usage = usage; self.historyUnavailable = historyUnavailable
    }
}
public extension UsageCounters {
    /// Nil remains unknown until a field has an actual observation.
    mutating func add(_ value: UsageCounters) throws {
        func sum(_ a: Int64?, _ b: Int64?) throws -> Int64? {
            guard let b else { return a }; guard b >= 0 else { throw UsageAccountingError.invalid }
            guard let a else { return b }
            let (total, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw UsageAccountingError.invalid }; return total
        }
        input = try sum(input, value.input); output = try sum(output, value.output)
        cachedInput = try sum(cachedInput, value.cachedInput); reasoning = try sum(reasoning, value.reasoning)
        cacheCreation = try sum(cacheCreation, value.cacheCreation)
    }
    func increment(since old: UsageCounters) throws -> UsageCounters {
        func delta(_ now: Int64?, _ before: Int64?) throws -> Int64? {
            guard let now else { return nil }; guard now >= 0 else { throw UsageAccountingError.invalid }
            guard let before else { return now }
            guard now >= before else { throw UsageAccountingError.regressed }; return now - before
        }
        return try UsageCounters(input: delta(input, old.input), output: delta(output, old.output), cachedInput: delta(cachedInput, old.cachedInput), reasoning: delta(reasoning, old.reasoning), cacheCreation: delta(cacheCreation, old.cacheCreation))
    }
}
public enum UsageAccountingError: Error, LocalizedError {
    case invalid, regressed, unsupported
    public var errorDescription: String? {
        switch self {
        case .invalid: "The provider reported invalid usage values."
        case .regressed: "The provider's cumulative counters decreased; this observation was not added."
        case .unsupported: "This transcript format has no supported usage observation."
        }
    }
}
