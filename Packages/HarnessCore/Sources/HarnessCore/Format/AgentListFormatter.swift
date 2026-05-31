import Foundation

/// Renders `[AgentSessionSummary]` into the two `harness-cli list-agents` output
/// shapes: tab-separated text lines and machine-readable JSON. Lives in HarnessCore
/// (not the CLI) so the formatting is unit-testable — the CLI stays a thin shell,
/// mirroring `SnapshotQueryFormatter`.
public enum AgentListFormatter {
    /// One tab-separated line per agent:
    /// `surfaceID \t workspace/session/tab \t agentName \t state \t age`.
    /// `state` is `waiting` when the agent is blocking on you, otherwise the raw
    /// `activity` (idle/working/awaiting/errored). `age` is a compact relative
    /// string from `lastActivityAt`. `now` is injectable for deterministic tests.
    public static func text(_ agents: [AgentSessionSummary], now: Date = .now) -> [String] {
        agents.map { agent in
            let location = "\(agent.workspaceName)/\(displaySession(agent))/\(displayTab(agent))"
            let state = agent.waiting ? "waiting" : agent.activity.rawValue
            let age = self.age(from: agent.lastActivityAt, to: now)
            return "\(agent.surfaceID)\t\(location)\t\(agent.agentName)\t\(state)\t\(age)"
        }
    }

    /// Pretty, stable JSON — the `--json` contract. Sorted keys + ISO-8601 dates so
    /// output is deterministic and round-trips back to `[AgentSessionSummary]`.
    public static func json(_ agents: [AgentSessionSummary]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(agents)
        return String(decoding: data, as: UTF8.self)
    }

    /// A matching decoder for callers/tests that consume `json(_:)` output.
    public static func decodeJSON(_ string: String) throws -> [AgentSessionSummary] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentSessionSummary].self, from: Data(string.utf8))
    }

    private static func displaySession(_ agent: AgentSessionSummary) -> String {
        agent.sessionName.isEmpty ? "-" : agent.sessionName
    }

    private static func displayTab(_ agent: AgentSessionSummary) -> String {
        agent.tabTitle.isEmpty ? "-" : agent.tabTitle
    }

    /// Compact relative age: `5s`, `3m`, `2h`, `4d`. Clamps negatives (clock skew)
    /// to `0s`. Public so the GUI Agent Inbox renders ages identically.
    public static func age(from then: Date, to now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(then))
        if seconds < 0 { return "0s" }
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}
