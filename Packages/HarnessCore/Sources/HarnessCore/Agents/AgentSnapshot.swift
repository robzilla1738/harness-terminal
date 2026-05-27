import Foundation

/// Identifier for the family of agent currently running in a pane. Driven by
/// `AgentDetector` (process-tree inspection) plus optional hints from CLI
/// hooks. Keep stable strings — they appear in JSON layout files and config.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claudeCode = "claude-code"
    case cursor
    case pi
    case hermes
    case openClaw = "openclaw"
    case aider
    case gemini
    case goose
    case generic

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor Agent"
        case .pi: return "Pi"
        case .hermes: return "Hermes"
        case .openClaw: return "OpenClaw"
        case .aider: return "Aider"
        case .gemini: return "Gemini"
        case .goose: return "Goose"
        case .generic: return "Agent"
        }
    }

    /// Two-letter chip shown in the sidebar (uppercase, fixed-width).
    public var chip: String {
        switch self {
        case .codex: return "CX"
        case .claudeCode: return "CC"
        case .cursor: return "CU"
        case .pi: return "PI"
        case .hermes: return "HM"
        case .openClaw: return "OC"
        case .aider: return "AI"
        case .gemini: return "GM"
        case .goose: return "GS"
        case .generic: return "AG"
        }
    }

    /// Hex color (without #) used for the status dot when this agent is running.
    public var dotHex: String {
        switch self {
        case .codex: return "10a37f"
        case .claudeCode: return "c47b58"
        case .cursor: return "5cc8ff"
        case .pi: return "b48cff"
        case .hermes: return "ff7e6b"
        case .openClaw: return "f5a623"
        case .aider: return "6ee7b7"
        case .gemini: return "8ab4f8"
        case .goose: return "f4b400"
        case .generic: return "9aa0a6"
        }
    }
}

public enum AgentActivity: String, Codable, Sendable {
    case idle
    case working
    case awaiting
    case errored
}

public struct AgentSnapshot: Codable, Sendable, Equatable {
    public var kind: AgentKind
    public var executable: String
    public var pid: Int32
    public var activity: AgentActivity
    public var lastActivityAt: Date

    public init(
        kind: AgentKind,
        executable: String,
        pid: Int32,
        activity: AgentActivity = .idle,
        lastActivityAt: Date = .now
    ) {
        self.kind = kind
        self.executable = executable
        self.pid = pid
        self.activity = activity
        self.lastActivityAt = lastActivityAt
    }
}
