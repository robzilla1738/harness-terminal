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

    public init(workspaceID: WorkspaceID, sessionID: SessionID, sessionName: String, tabID: TabID, tabTitle: String, paneID: PaneID, surfaceID: SurfaceID, line: Int, text: String) {
        self.workspaceID = workspaceID; self.sessionID = sessionID; self.sessionName = sessionName
        self.tabID = tabID; self.tabTitle = tabTitle; self.paneID = paneID; self.surfaceID = surfaceID
        self.line = line; lineFingerprint = OutputSearch.fingerprint(text)
        excerpt = String(text.prefix(500))
    }
}

public struct OutputSearchPage: Codable, Sendable {
    public var matches: [OutputSearchMatch]
    public var hasMore: Bool
    public var epoch: String
    public var revision: Int
    public init(matches: [OutputSearchMatch], hasMore: Bool, epoch: String, revision: Int) {
        self.matches = matches; self.hasMore = hasMore; self.epoch = epoch; self.revision = revision
    }
}

public enum OutputSearch {
    public static func fingerprint(_ line: String) -> UInt64 {
        line.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping.utf8.reduce(14695981039346656037) {
            ($0 ^ UInt64($1)) &* 1099511628211
        }
    }
}
