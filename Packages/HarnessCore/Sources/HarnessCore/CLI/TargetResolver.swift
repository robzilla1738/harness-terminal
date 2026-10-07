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

    struct Candidate {
        let id: String
        let labels: [String]
    }

    public static func resolve(_ token: String, kind: Kind, in snapshot: SessionSnapshot) -> Resolution {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let (all, positional) = candidates(kind, snapshot)
        guard !needle.isEmpty else { return .notFound("empty \(kind.rawValue)") }
        if let exact = all.first(where: { $0.id.caseInsensitiveCompare(needle) == .orderedSame }) {
            return .resolved(exact.id)
        }
        let labeled = unique(all.filter { $0.labels.contains { $0.caseInsensitiveCompare(needle) == .orderedSame } })
        if labeled.count == 1 { return .resolved(labeled[0]) }
        if labeled.count > 1 { return .ambiguous("\(kind.rawValue) '\(needle)'", matches: labeled) }
        if let position = Int(needle), position >= 1, needle.allSatisfy(\.isNumber) {
            guard position <= positional.count else {
                return .notFound("no \(kind.rawValue) at position \(position) (there are \(positional.count))")
            }
            return .resolved(positional[position - 1])
        }
        if needle.count >= 4 {
            let lower = needle.lowercased()
            let fragment = unique(all.filter {
                let id = $0.id.lowercased()
                return id.hasPrefix(lower) || id.hasSuffix(lower)
            })
            if fragment.count == 1 { return .resolved(fragment[0]) }
            if fragment.count > 1 { return .ambiguous("\(kind.rawValue) '\(needle)'", matches: fragment) }
        }
        return .notFound("no \(kind.rawValue) matches '\(needle)'")
    }

    private static func unique(_ candidates: [Candidate]) -> [String] {
        var seen = Set<String>()
        return candidates.map(\.id).filter { seen.insert($0).inserted }
    }

    /// Everything addressable of `kind`, plus the ones a position counts through: sessions
    /// of the active workspace, tabs of the active session, panes of the active tab.
    private static func candidates(_ kind: Kind, _ snapshot: SessionSnapshot) -> (all: [Candidate], positional: [String]) {
        let sessions = snapshot.workspaces.flatMap(\.sessions)
        let workspace = snapshot.activeWorkspace
        let activeSession = workspace?.sessions.first { $0.id == workspace?.activeSessionID } ?? workspace?.sessions.first
        let activeTab = activeSession?.activeTab ?? activeSession?.tabs.first
        switch kind {
        case .session:
            let all = sessions.map { Candidate(id: $0.id.uuidString, labels: [$0.name].filter { !$0.isEmpty }) }
            return (all, (workspace?.sessions ?? []).map(\.id.uuidString))
        case .tab:
            let all = sessions.flatMap(\.tabs).map { tab in
                Candidate(id: tab.id.uuidString, labels: [tab.title].filter { !$0.isEmpty })
            }
            return (all, (activeSession?.tabs ?? []).map(\.id.uuidString))
        case .surface, .pane:
            let all = sessions.flatMap(\.tabs).flatMap { tab in
                tab.rootPane.allLeaves().map { leaf in
                    let id = kind == .surface ? leaf.surfaceID.uuidString : leaf.id.uuidString
                    // A lone pane answers to its tab's title; a split pane only by ID or position.
                    let label = tab.rootPane.allLeaves().count == 1 ? [tab.title].filter { !$0.isEmpty } : []
                    return Candidate(id: id, labels: label)
                }
            }
            let positional = (activeTab?.rootPane.allLeaves() ?? []).map { kind == .surface ? $0.surfaceID.uuidString : $0.id.uuidString }
            return (all, positional)
        }
    }
}

/// `harness-cli` exit statuses, shared with the JSON API.
public enum CLIExit {
    public static let ok: Int32 = 0
    public static let failed: Int32 = 1
    public static let usage: Int32 = 2
    public static let targetNotFound: Int32 = 3
    public static let unreachable: Int32 = 4
    public static let interrupted: Int32 = 130
}
