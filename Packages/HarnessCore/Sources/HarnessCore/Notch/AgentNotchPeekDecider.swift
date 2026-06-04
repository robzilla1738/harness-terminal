import Foundation

/// One transient notch peek: the row that changed and why it deserves a glance.
public struct AgentNotchPeekEvent: Equatable, Sendable {
    public enum Reason: Int, Equatable, Sendable, Comparable {
        // Priority order: a blocked agent beats an error beats a completion.
        case finished = 0
        case errored = 1
        case needsInput = 2

        public static func < (lhs: Reason, rhs: Reason) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var row: AgentNotchRowSummary
    public var reason: Reason

    public init(row: AgentNotchRowSummary, reason: Reason) {
        self.row = row
        self.reason = reason
    }
}

/// Pure transition detector behind the notch auto-peek: compares the previous refresh's
/// per-row state against the current rows and emits peek-worthy transitions. The caller
/// (view model) owns suppression policy (app frontmost, HUD open, cooldowns); this stays
/// a deterministic state diff so it can be table-tested.
public enum AgentNotchPeekDecider {
    public struct RowState: Equatable, Sendable {
        public var activity: AgentActivity?
        public var waiting: Bool

        public init(activity: AgentActivity?, waiting: Bool) {
            self.activity = activity
            self.waiting = waiting
        }
    }

    /// Diff `rows` against `previous`. A nil `previous` is the initial seed (app launch /
    /// HUD enable): it produces no events — peeking the whole backlog would be a storm.
    /// Rows without an agent never peek. A *new* agent row only peeks when it appears
    /// already blocked (spawned straight into a permission prompt).
    public static func decide(
        previous: [String: RowState]?,
        rows: [AgentNotchRowSummary]
    ) -> (events: [AgentNotchPeekEvent], next: [String: RowState]) {
        var next: [String: RowState] = [:]
        next.reserveCapacity(rows.count)
        for row in rows {
            next[row.id] = RowState(activity: row.agentActivity, waiting: row.waitingCount > 0)
        }
        guard let previous else { return ([], next) }

        var events: [AgentNotchPeekEvent] = []
        for row in rows where row.agentKind != nil {
            let now = next[row.id]!
            guard let prev = previous[row.id] else {
                // Brand-new agent row: peek only if it's already blocked on the user.
                if now.waiting { events.append(AgentNotchPeekEvent(row: row, reason: .needsInput)) }
                continue
            }
            if !prev.waiting, now.waiting {
                events.append(AgentNotchPeekEvent(row: row, reason: .needsInput))
            } else if prev.activity != .errored, now.activity == .errored {
                events.append(AgentNotchPeekEvent(row: row, reason: .errored))
            } else if prev.activity == .working, now.activity == .idle, !now.waiting {
                events.append(AgentNotchPeekEvent(row: row, reason: .finished))
            }
        }
        // Highest-priority first; ties broken by recency so the freshest change wins.
        events.sort { lhs, rhs in
            if lhs.reason != rhs.reason { return lhs.reason > rhs.reason }
            return (lhs.row.lastActivityAt ?? .distantPast) > (rhs.row.lastActivityAt ?? .distantPast)
        }
        return (events, next)
    }
}
