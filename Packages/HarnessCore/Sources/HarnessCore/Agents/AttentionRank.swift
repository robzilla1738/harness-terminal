import Foundation

/// The one order for "what needs me": an explicit request (a hook or `notify` asking for you)
/// → blocked (an agent or program waiting on you) → error → done and unseen → working → idle,
/// ties broken by the most recent activity. The notch, the menu-bar agent
/// list, the Dock badge, and the overview all ask here so they never disagree.
public enum AttentionRank: Int, Comparable, Sendable {
    case idle = 0
    case working
    case done
    case error
    case blocked
    case waiting

    public static func < (lhs: AttentionRank, rhs: AttentionRank) -> Bool { lhs.rawValue < rhs.rawValue }

    /// `waiting`: a tab marked waiting (a hook or `notify`). `activity`: the detected agent's
    /// state. `mark`: the program's own OSC 7501 / progress status.
    public static func of(waiting: Bool = false, activity: AgentActivity? = nil, mark: ProgramMark.Attention? = nil) -> AttentionRank {
        if waiting { return .waiting }
        if activity == .awaiting || mark == .blocked { return .blocked }
        if activity == .errored || mark == .error { return .error }
        if mark == .done { return .done }
        if activity == .working || mark == .working { return .working }
        return .idle
    }

    public static func of(_ tab: Tab) -> AttentionRank {
        of(waiting: tab.status == .waiting, activity: tab.agent?.activity, mark: tab.programMark?.attention)
    }

    /// Needs a person now: the Dock badge counts these.
    public var needsYou: Bool { self >= .error }

    /// Highest rank first, then most recent activity, then the original order.
    public static func sorted<T>(_ items: [T], rank: (T) -> AttentionRank, lastActivity: (T) -> Date?) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let (a, b) = (rank(lhs.element), rank(rhs.element))
            if a != b { return a > b }
            if let x = lastActivity(lhs.element), let y = lastActivity(rhs.element), x != y { return x > y }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
