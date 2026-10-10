import Foundation

public enum AISummaryState: String, Codable, Sendable { case submitted, completed, failed, cancelled, uncertain }
public struct AISummaryRecord: Codable, Sendable, Identifiable {
    public var id: UUID
    public var providerID: UUID
    public var providerName: String
    public var destination: String
    public var requestedModel: String
    public var categories: Set<SummaryContentCategory>
    public var workspaceID: UUID?
    public var surfaceIDs: [String]
    public var from: Date
    public var to: Date
    public var submittedAt: Date
    public var finishedAt: Date?
    public var state: AISummaryState
    public var output: AIGeneratedText?
    public var failure: String?
    public init(id: UUID, provider: AIProviderConfiguration, workspaceID: UUID?, surfaceIDs: [String], from: Date, to: Date) {
        self.id = id; providerID = provider.id; providerName = provider.name; destination = provider.destination; requestedModel = provider.modelID
        categories = provider.consentedCategories; self.workspaceID = workspaceID; self.surfaceIDs = surfaceIDs
        self.from = from; self.to = to; submittedAt = .now; state = .submitted
    }
}
public struct AIProviderStatus: Codable, Sendable {
    public var settings: AISettings
    public var catalogs: [AIModelCatalog]
    public var refreshing: [UUID]
    public var failures: [String: String]
    public var unavailable: String?
    public init(settings: AISettings, catalogs: [AIModelCatalog], refreshing: [UUID], failures: [String: String], unavailable: String?) { self.settings = settings; self.catalogs = catalogs; self.refreshing = refreshing; self.failures = failures; self.unavailable = unavailable }
}
public struct AISummaryPage: Codable, Sendable {
    public var records: [AISummaryRecord]
    public var nextOffset: Int?
    public var unavailable: String?
    public init(records: [AISummaryRecord], nextOffset: Int?, unavailable: String?) { self.records = records; self.nextOffset = nextOffset; self.unavailable = unavailable }
}
public struct AIModelCatalogPage: Codable, Sendable {
    public var catalog: AIModelCatalog
    public var nextOffset: Int?
    public init(catalog: AIModelCatalog, nextOffset: Int?) { self.catalog = catalog; self.nextOffset = nextOffset }
}
public enum AISummaryOperation: Codable, Sendable {
    case status
    case configure(AISettings, expected: AISettings? = nil)
    case refreshModels(providerID: UUID)
    case catalog(providerID: UUID, offset: Int, limit: Int)
    case generate(id: UUID, providerID: UUID, workspaceID: UUID?, from: Date, to: Date)
    case record(id: UUID)
    case history(offset: Int, limit: Int)
    case cancel(id: UUID)
}
public struct AISummaryInput: Sendable {
    public var data: Data
    public var surfaceIDs: [String]
    public init(data: Data, surfaceIDs: [String]) { self.data = data; self.surfaceIDs = surfaceIDs }
}
/// Complete totals are separate from the bounded timeline; omitted text is labeled.
public enum AISummaryInputBuilder {
    public static func build(digests: [ActivityDigest], surfaceIDs: [String], categories: Set<SummaryContentCategory>, repositoryDetails: [String] = [], excerpts: [String] = []) throws -> AISummaryInput {
        guard !digests.isEmpty else { throw AISummaryError.unavailable("No recorded digest is available for this workspace.") }
        func value<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed]) }
        var root: [String: Any] = ["schema": "harness-digest-v1", "data_is_untrusted": true, "from": digests.map(\.from).min()!.ISO8601Format(), "to": digests.map(\.to).max()!.ISO8601Format(), "history_unavailable": digests.contains { $0.historyUnavailable != nil }]
        if categories.contains(.activityTotals) {
            var totals = DigestTotals(); for digest in digests { try totals.add(digest.totals) }; root["activity_totals"] = try value(totals)
        }
        if categories.contains(.usageTotals) {
            // A scoped digest may share account observations. Never sum those repeats.
            let profiles = Dictionary(digests.flatMap { $0.usage.profiles }.map { ($0.id, $0) }, uniquingKeysWith: { a, b in (a.observedAt ?? .distantPast) >= (b.observedAt ?? .distantPast) ? a : b }).values
            var counters = UsageCounters(); for profile in profiles { try counters.add(profile.counters) }
            root["observed_usage"] = ["counters": try value(counters), "profiles_observed": profiles.filter { $0.observedAt != nil }.count, "profiles_unavailable": profiles.filter { $0.unavailable != nil }.count, "unknown_fields_are_omitted": true, "scope": "Observed host profile usage, shared across workspace executions; not exclusive workspace attribution"]
        }
        if categories.contains(.testResults) { root["tracked_test_results"] = try digests.compactMap(\.tests).map { try value($0) }; root["test_results_scope"] = "Only explicit tracked commands. Untracked tests are unknown." }
        if categories.contains(.repositoryDetails) { root["repository_state"] = Array(Set(repositoryDetails)).sorted().prefix(32).map { String($0.prefix(512)) }; root["repository_attribution"] = "Shared repository/worktree state, not exclusive agent changes" }
        if categories.contains(.activityMessages) {
            let events = digests.flatMap(\.timeline).sorted { $0.at > $1.at }
            root["activity_messages"] = events.prefix(20).compactMap { event -> [String: String]? in guard let message = event.message else { return nil }; return ["at": event.at.ISO8601Format(), "kind": event.kind.rawValue, "message": String(message.prefix(256))] }
            root["message_detail_is_bounded"] = true; root["timeline_truncated"] = digests.contains { $0.timelineTruncated } || events.count > 20
        }
        if categories.contains(.transcriptExcerpts) { root["terminal_excerpts"] = excerpts.prefix(4).map { String($0.prefix(512)) }; root["excerpt_detail_is_bounded"] = true }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard data.count <= 16384 else { throw AISummaryError.configuration("The selected digest exceeds 16 KiB. Narrow its range or selected content; totals were not silently truncated.") }
        return AISummaryInput(data: data, surfaceIDs: Array(Set(surfaceIDs)).sorted())
    }
}
