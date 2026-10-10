import Foundation

/// Usage attribution metadata outlives closed execution detail for the aggregate
/// retention horizon. It contains no conversation, launch arguments or event text.
public struct RunUsageAttribution: Codable, Equatable, Sendable {
    public var runID: UUID
    public var surfaceID: String
    public var provider: AgentKind
    public var profile: String
    public var endedAt: Date?
    public var directory: String?
    public var repository: GitRepository?
    public init(_ run: AgentRun) {
        runID = run.id; surfaceID = run.surfaceID; provider = run.provider; profile = run.profile
        endedAt = run.endedAt; directory = run.directory; repository = run.repository
    }
}
public struct RunUsageBucket: Codable, Sendable {
    public var runID: UUID
    public var profileID: UUID
    public var provider: AgentKind
    public var profile: String
    public var from: Date
    public var to: Date
    public var counters: UsageCounters
    public var observedAt: Date
    public init(runID: UUID, profileID: UUID, provider: AgentKind, profile: String, from: Date, to: Date, observedAt: Date) {
        self.runID = runID; self.profileID = profileID; self.provider = provider; self.profile = profile
        self.from = from; self.to = to; self.observedAt = observedAt; counters = UsageCounters()
    }
}
public struct RepositoryActivityDigest: Codable, Sendable {
    /// Canonical Git common directory groups linked worktrees into one repository.
    /// Nil means identity is unknown; that group is never presented as a repository.
    public var repository: String?
    public var worktrees: [String]
    public var totals: DigestTotals
    public var tests: TestExecutionSummary?
    public var usage: [ProfileUsage]
    public var coverageWarnings: [String]
    public init(repository: String?, worktrees: [String], totals: DigestTotals, usage: [ProfileUsage], coverageWarnings: [String]) {
        self.repository = repository; self.worktrees = worktrees; self.totals = totals; self.usage = usage; self.coverageWarnings = coverageWarnings
    }
}
public struct RepositoryDigestPage: Codable, Sendable {
    public var hostID: UUID
    public var from: Date
    public var to: Date
    public var reports: [RepositoryActivityDigest]
    public var nextOffset: Int?
    public var historyUnavailable: String?
    public init(hostID: UUID, from: Date, to: Date, reports: [RepositoryActivityDigest], nextOffset: Int?, historyUnavailable: String?) {
        self.hostID = hostID; self.from = from; self.to = to; self.reports = reports; self.nextOffset = nextOffset; self.historyUnavailable = historyUnavailable
    }
}

public enum RepositoryDigestError: Error, LocalizedError {
    case page, budget
    public var errorDescription: String? {
        switch self {
        case .page: "Repository report offset must be 0–1,000,000 and page size 1–100."
        case .budget: "The repository report exceeded its bounded query budget. Narrow the date range and retry; no partial totals were presented as complete."
        }
    }
}
