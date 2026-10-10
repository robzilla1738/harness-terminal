import Foundation

public struct OutputSearchMatch: Codable, Sendable, Equatable {
    public var workspaceID: WorkspaceID
    public var sessionID: SessionID
    public var sessionName: String
    public var tabID: TabID
    public var tabTitle: String
    public var paneID: PaneID
    public var surfaceID: SurfaceID
    public var line: Int
    public var lineFingerprint: UInt64
    public var excerpt: String
    /// First exact UTF-16 match reported by the isolated regex worker. Nil for
    /// literal searches and older daemons; clients must not recompute unsafe regex.
    public var regexSpan: OutputSearchSpan?

    public init(workspaceID: WorkspaceID, sessionID: SessionID, sessionName: String, tabID: TabID, tabTitle: String, paneID: PaneID, surfaceID: SurfaceID, line: Int, text: String) {
        self.workspaceID = workspaceID; self.sessionID = sessionID; self.sessionName = sessionName
        self.tabID = tabID; self.tabTitle = tabTitle; self.paneID = paneID; self.surfaceID = surfaceID
        self.line = line; lineFingerprint = OutputSearch.fingerprint(text)
        excerpt = String(text.prefix(500))
    }
}
public struct OutputSearchSpan: Codable, Sendable, Equatable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) { self.location = location; self.length = length }
}

public struct OutputSearchPage: Codable, Sendable {
    public var matches: [OutputSearchMatch]
    public var hasMore: Bool
    public var epoch: String
    public var revision: Int
    public var generation: String?
    public init(matches: [OutputSearchMatch], hasMore: Bool, epoch: String, revision: Int, generation: String? = nil) {
        self.matches = matches; self.hasMore = hasMore; self.epoch = epoch; self.revision = revision; self.generation = generation
    }
}

public enum OutputSearch {
    public static func fingerprint(_ line: String) -> UInt64 {
        line.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping.utf8.reduce(14695981039346656037) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
    }
}

/// Time filters select recorded executions overlapping the range. They do not
/// invent per-line timestamps for a mutable terminal screen.
public struct OutputSearchFilter: Codable, Sendable, Equatable {
    public var regex: Bool
    public var agent: AgentKind?
    public var from: Date?
    public var to: Date?
    public init(regex: Bool = false, agent: AgentKind? = nil, from: Date? = nil, to: Date? = nil) { self.regex = regex; self.agent = agent; self.from = from; self.to = to }
    public var selectsExecutions: Bool { agent != nil || from != nil || to != nil }
    public func validate() throws {
        guard (from?.timeIntervalSince1970.isFinite ?? true), (to?.timeIntervalSince1970.isFinite ?? true),
              from == nil || to == nil || to! > from! else { throw OutputSearchFilterError.invalid }
    }
}
public enum OutputSearchFilterError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? { "Execution time filters need finite timestamps and an ordered time range." }
}
