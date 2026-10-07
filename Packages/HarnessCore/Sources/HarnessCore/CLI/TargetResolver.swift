import Foundation

/// Resolves what a person types after `--session`, `--tab`, `--surface`, or `--pane` to a
/// full ID. Tried in order: the full ID, a case-insensitive label, a 1-based position, then
/// a unique ID prefix or suffix of at least four characters.
public enum TargetResolver {
    public enum Kind: String, Sendable {
        case session, tab, surface, pane
    }

    public enum Resolution: Equatable, Sendable {
        case resolved(String)
        case notFound(String)
        case ambiguous(String, matches: [String])

        public var message: String {
            switch self {
            case let .resolved(id): return id
            case let .notFound(text): return text
            case let .ambiguous(text, matches): return "\(text) matches \(matches.count): \(matches.joined(separator: ", "))"
            }
        }
    }

    public static func resolve(_ token: String, kind: Kind, in snapshot: SessionSnapshot) -> Resolution {
        let (all, positional) = candidates(kind, snapshot)
        return resolve(token, kind: kind, candidates: all, positional: positional)
    }

    /// The matching rules over any candidate list. `positional` is what a 1-based number counts
    /// through. Returns the candidate's primary `id`.
    public static func resolve(_ token: String, kind: Kind, candidates all: [TargetCandidate], positional: [String]) -> Resolution {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return .notFound("empty \(kind.rawValue)") }
        if let exact = all.first(where: { $0.ids.contains { $0.caseInsensitiveCompare(needle) == .orderedSame } }) {
            return .resolved(exact.id)
        }
        let labeled = unique(all.filter { $0.labels.contains { $0.caseInsensitiveCompare(needle) == .orderedSame } })
        if labeled.count == 1 { return .resolved(labeled[0]) }
        if labeled.count > 1 { return .ambiguous("\(kind.rawValue) '\(needle)'", matches: labeled) }
        let isNumber = needle.allSatisfy(\.isNumber)
        if isNumber, let position = Int(needle), position >= 1, position <= positional.count {
            return .resolved(positional[position - 1])
        }
        if needle.count >= 4 {
            let lower = needle.lowercased()
            let fragment = unique(all.filter { candidate in
                candidate.ids.contains { $0.lowercased().hasPrefix(lower) || $0.lowercased().hasSuffix(lower) }
            })
            if fragment.count == 1 { return .resolved(fragment[0]) }
            if fragment.count > 1 { return .ambiguous("\(kind.rawValue) '\(needle)'", matches: fragment) }
        }
        if isNumber, needle.count < 4 {
            return .notFound("no \(kind.rawValue) at position \(needle) (there are \(positional.count))")
        }
        return .notFound("no \(kind.rawValue) matches '\(needle)'")
    }

    private static func unique(_ candidates: [TargetCandidate]) -> [String] {
        var seen = Set<String>()
        return candidates.map(\.id).filter { seen.insert($0).inserted }
    }

    /// Everything addressable of `kind`, plus the ones a position counts through: sessions
    /// of the active workspace, tabs of the active session, panes of the active tab.
    static func candidates(_ kind: Kind, _ snapshot: SessionSnapshot) -> (all: [TargetCandidate], positional: [String]) {
        let workspace = snapshot.activeWorkspace
        let activeSession = workspace?.sessions.first { $0.id == workspace?.activeSessionID } ?? workspace?.sessions.first
        let activeTab = activeSession?.activeTab ?? activeSession?.tabs.first
        switch kind {
        case .session:
            let all = snapshot.workspaces.flatMap { workspace in
                workspace.sessions.map { TargetCandidate(id: $0.id.uuidString, labels: [SessionDisplayName.title(of: $0, in: workspace)]) }
            }
            return (all, (workspace?.sessions ?? []).map(\.id.uuidString))
        case .tab:
            let all = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).map { tab in
                TargetCandidate(id: tab.id.uuidString, labels: [tab.title])
            }
            return (all, (activeSession?.tabs ?? []).map(\.id.uuidString))
        case .surface, .pane:
            let all = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap { tab in
                let leaves = tab.rootPane.allLeaves()
                return leaves.map { leaf in
                    TargetCandidate.pane(leaf, kind: kind, label: leaves.count == 1 ? tab.title : nil)
                }
            }
            let positional = (activeTab?.rootPane.allLeaves() ?? []).map { kind == .surface ? $0.surfaceID.uuidString : $0.id.uuidString }
            return (all, positional)
        }
    }
}

/// Something a target can name. `id` is what resolution returns; `otherIDs` are accepted too
/// (a pane answers to its surface ID and its pane ID). Empty labels are ignored.
public struct TargetCandidate: Equatable, Sendable {
    public var id: String
    public var otherIDs: [String]
    public var labels: [String]

    public init(id: String, otherIDs: [String] = [], labels: [String] = []) {
        self.id = id
        self.otherIDs = otherIDs
        self.labels = labels.filter { !$0.isEmpty }
    }

    var ids: [String] { [id] + otherIDs }

    /// A pane, keyed by surface or pane ID depending on what the caller wants back.
    /// Only a pane alone in its tab answers to the tab's title.
    static func pane(_ leaf: PaneLeaf, kind: TargetResolver.Kind, label: String?) -> TargetCandidate {
        let surface = leaf.surfaceID.uuidString
        let pane = leaf.id.uuidString
        return kind == .pane
            ? TargetCandidate(id: pane, otherIDs: [surface], labels: label.map { [$0] } ?? [])
            : TargetCandidate(id: surface, otherIDs: [pane], labels: label.map { [$0] } ?? [])
    }
}

/// `harness-cli` exit statuses, shared with the JSON API.
public enum CLIExit {
    public static let ok = Int32(APIExit.ok.rawValue)
    public static let failed = Int32(APIExit.failed.rawValue)
    public static let usage = Int32(APIExit.badArguments.rawValue)
    public static let targetNotFound = Int32(APIExit.ambiguous.rawValue)
    public static let unreachable = Int32(APIExit.unreachable.rawValue)
    public static let interrupted = Int32(APIExit.interrupted.rawValue)
}
