import Foundation

/// Identifier for the family of agent currently running in a pane. Driven by
/// `AgentDetector` (process-tree inspection) plus optional hints from CLI
/// hooks. Keep stable strings — they appear in JSON layout files and config.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case codex
    case claudeCode = "claude-code"
    case cursor
    case grok
    case pi
    case hermes
    case openClaw = "openclaw"
    case openCode = "opencode"
    case aider
    case gemini
    case goose
    case copilot
    case cline
    case kilo
    case qwen
    case amp
    case droid
    case crush
    case kiro
    case vibe
    case openhands
    case auggie
    case kimi
    case devin
    case codebuff
    case commandCode = "command-code"
    case qoder
    case coderabbit
    case bob
    case muse
    case antigravity
    case junie
    case codebuddy
    case oz
    case abacus = "abacus-ai"
    case minimax = "minimax-code"
    case trae
    case generic

    /// Preserve the last public catalog for clients that have not negotiated the
    /// expanded identities. Projection never changes the canonical observation.
    public func projected(for capabilities: [String]) -> AgentKind {
        if capabilities.contains(DaemonStats.agentIdentities) { return self }
        switch self {
        case .devin, .codebuff, .commandCode, .qoder, .coderabbit, .bob, .muse,
             .antigravity, .junie, .codebuddy, .oz, .abacus, .minimax, .trae: return .generic
        default: return self
        }
    }

    /// Short name used in a tab, without the marketing words.
    public var commandToken: String {
        switch self {
        case .codex: return "codex"
        case .claudeCode: return "claude"
        case .cursor: return "cursor"
        case .grok: return "grok"
        case .pi: return "pi"
        case .hermes: return "hermes"
        case .openClaw: return "openclaw"
        case .openCode: return "opencode"
        case .aider: return "aider"
        case .gemini: return "gemini"
        case .goose: return "goose"
        case .copilot: return "copilot"
        case .cline: return "cline"
        case .kilo: return "kilo"
        case .qwen: return "qwen"
        case .amp: return "amp"
        case .droid: return "droid"
        case .crush: return "crush"
        case .kiro: return "kiro"
        case .vibe: return "vibe"
        case .openhands: return "openhands"
        case .auggie: return "auggie"
        case .kimi: return "kimi"
        case .devin: return "devin"
        case .codebuff: return "codebuff"
        case .commandCode: return "command-code"
        case .qoder: return "qoder"
        case .coderabbit: return "coderabbit"
        case .bob: return "bob"
        case .muse: return "muse"
        case .antigravity: return "agy"
        case .junie: return "junie"
        case .codebuddy: return "codebuddy"
        case .oz: return "oz"
        case .abacus: return "abacusai"
        case .minimax: return "mcode"
        case .trae: return "traecli"
        case .generic: return "agent"
        }
    }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor Agent"
        case .grok: return "Grok"
        case .pi: return "Pi"
        case .hermes: return "Hermes"
        case .openClaw: return "OpenClaw"
        case .openCode: return "OpenCode"
        case .aider: return "Aider"
        case .gemini: return "Gemini"
        case .goose: return "Goose"
        case .copilot: return "GitHub Copilot"
        case .cline: return "Cline"
        case .kilo: return "Kilo Code"
        case .qwen: return "Qwen Code"
        case .amp: return "Amp"
        case .droid: return "Droid"
        case .crush: return "Crush"
        case .kiro: return "Kiro"
        case .vibe: return "Mistral Vibe"
        case .openhands: return "OpenHands"
        case .auggie: return "Auggie"
        case .kimi: return "Kimi Code"
        case .devin: return "Devin"
        case .codebuff: return "Codebuff"
        case .commandCode: return "Command Code"
        case .qoder: return "Qoder"
        case .coderabbit: return "CodeRabbit"
        case .bob: return "IBM Bob"
        case .muse: return "Muse Code"
        case .antigravity: return "Antigravity"
        case .junie: return "Junie"
        case .codebuddy: return "CodeBuddy"
        case .oz: return "Warp Oz"
        case .abacus: return "Abacus AI"
        case .minimax: return "MiniMax Code"
        case .trae: return "Trae Code"
        case .generic: return "Agent"
        }
    }

    /// Two-letter chip shown in the sidebar (uppercase, fixed-width).
    public var chip: String {
        switch self {
        case .codex: return "CX"
        case .claudeCode: return "CC"
        case .cursor: return "CU"
        case .grok: return "GK"
        case .pi: return "PI"
        case .hermes: return "HM"
        case .openClaw: return "CL"
        case .openCode: return "OC"
        case .aider: return "AI"
        case .gemini: return "GM"
        case .goose: return "GS"
        case .copilot: return "CP"
        case .cline: return "CL"
        case .kilo: return "KL"
        case .qwen: return "QW"
        case .amp: return "AM"
        case .droid: return "DR"
        case .crush: return "CR"
        case .kiro: return "KR"
        case .vibe: return "MV"
        case .openhands: return "OH"
        case .auggie: return "AU"
        case .kimi: return "KM"
        case .devin: return "DV"
        case .codebuff: return "CB"
        case .commandCode: return "CM"
        case .qoder: return "QD"
        case .coderabbit: return "RB"
        case .bob: return "BB"
        case .muse: return "MC"
        case .antigravity: return "AV"
        case .junie: return "JN"
        case .codebuddy: return "BD"
        case .oz: return "OZ"
        case .abacus: return "AB"
        case .minimax: return "MM"
        case .trae: return "TR"
        case .generic: return "AG"
        }
    }

    /// Hex color (without #) used for the status dot when this agent is running.
    public var dotHex: String {
        switch self {
        case .codex: return "10a37f"
        case .claudeCode: return "d97757"
        case .cursor: return "5cc8ff"
        case .grok: return "1d9bf0"
        case .pi: return "b48cff"
        case .hermes: return "ff7e6b"
        case .openClaw: return "f5a623"
        case .openCode: return "56b6c2"
        case .aider: return "6ee7b7"
        case .gemini: return "8ab4f8"
        case .goose: return "f4b400"
        case .copilot: return "7C74D4"
        case .cline: return "697585"
        case .kilo: return "8A7B36"
        case .qwen: return "7563BE"
        case .amp: return "53725B"
        case .droid: return "AC6541"
        case .crush: return "9B438F"
        case .kiro: return "7545B1"
        case .vibe: return "AB6034"
        case .openhands: return "996237"
        case .auggie: return "556FA1"
        case .kimi: return "4D67B3"
        case .devin: return "5E71A5"
        case .codebuff: return "AB633B"
        case .commandCode: return "687385"
        case .qoder: return "607792"
        case .coderabbit: return "AB643B"
        case .bob: return "587CB5"
        case .muse: return "647AB1"
        case .antigravity: return "6585B1"
        case .junie: return "67844E"
        case .codebuddy: return "5B83AB"
        case .oz: return "637BA0"
        case .abacus: return "667E98"
        case .minimax: return "9A6885"
        case .trae: return "54866C"
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

/// Best-effort fallback for when the daemon's process-tree scan can't see the
/// agent (e.g. Claude Code launches as a renamed Node binary that exec's
/// without preserving argv[0]). We infer the kind from the terminal title the
/// agent sets via OSC 0/2.
///
/// Robust to the leading "thinking" glyphs agents prepend (`✱`, `✶`, `✻`, `★`,
/// `*`, `•`, emoji, whitespace) and to single-word abbreviations the agent uses
/// for itself (`Claude` for Claude Code, `Cursor` for Cursor Agent).
public enum AgentTitleInference {
    public static func kind(from rawTitle: String) -> AgentKind? {
        guard !rawTitle.isEmpty else { return nil }
        let lower = rawTitle.lowercased()
        // Skip every leading character that isn't a letter or digit — covers
        // ASCII punctuation, unicode glyphs like ✱✶✻★, and emoji.
        guard let start = lower.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let trimmed = String(lower[start...])

        // Exact / prefixed match against the full displayName ("Claude Code", "Cursor Agent").
        for kind in AgentKind.allCases where kind != .generic {
            let name = kind.displayName.lowercased()
            if matches(trimmed, head: name) { return kind }
            // Some agents emit their stable raw value in titles ("claude-code").
            let raw = kind.rawValue.lowercased()
            if raw != name, matches(trimmed, head: raw) { return kind }
        }
        // First-word fallback for multi-word names (`Claude` / `Cursor`). Skip
        // single-word agents and `.generic` / `.pi` to avoid false positives
        // like "agent.swift" or "pip install" matching arbitrary content.
        for kind: AgentKind in [.claudeCode, .cursor] {
            let parts = kind.displayName.lowercased().split(separator: " ")
            guard parts.count > 1, let first = parts.first else { continue }
            if matches(trimmed, head: String(first)) { return kind }
        }
        return nil
    }

    /// True if `trimmed` is exactly `head` or `head` followed by a non-alphanumeric
    /// boundary. Prevents partial-word collisions ("claudette" matching "claude").
    private static func matches(_ trimmed: String, head: String) -> Bool {
        guard trimmed.hasPrefix(head) else { return false }
        if trimmed.count == head.count { return true }
        let next = trimmed[trimmed.index(trimmed.startIndex, offsetBy: head.count)]
        return !(next.isLetter || next.isNumber)
    }
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
