import Foundation

/// Writes per-agent hook config files so each known agent CLI calls back into Harness via
/// `harness-cli notify --surface "$HARNESS_SURFACE"`. Shared by the CLI (`install-hooks`)
/// and the Settings "Install hooks" button — UI-agnostic (no `print`/`exit`), so the GUI
/// can call it directly. Configs are **deep-merged** into the agent's existing file (via
/// `JSONMerge`) and backed up first — never clobbered. Per-agent guides live in
/// `docs/agent-hooks/<agent>.md`.
public enum AgentHookInstaller {
    public struct InstallResult: Sendable, Equatable {
        /// The config file that was written.
        public let path: URL
        /// The backup that was made of a pre-existing file, if any.
        public let backedUp: URL?
        /// True when the existing file wasn't valid JSON and was replaced (backup kept).
        public let replacedInvalidJSON: Bool
    }

    public enum InstallError: Error, Equatable {
        /// `agent` has no hook integration (e.g. aider/gemini/goose/generic).
        case unsupported(AgentKind)
    }

    /// Agents Harness can install hooks for.
    public static let installableAgents: [AgentKind] = [
        .codex, .claudeCode, .cursor, .pi, .hermes, .openClaw,
    ]

    public static func canInstall(_ agent: AgentKind) -> Bool {
        installableAgents.contains(agent)
    }

    /// The config file an agent's hooks live in, or nil when unsupported.
    public static func hookConfigURL(for agent: AgentKind, homeOverride: URL? = nil) -> URL? {
        let home = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
        switch agent {
        case .claudeCode: return home.appendingPathComponent(".claude/settings.json")
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/agent-hooks.json")
        case .pi: return home.appendingPathComponent(".pi/hooks.json")
        case .hermes: return home.appendingPathComponent(".hermes/hooks.json")
        case .openClaw: return home.appendingPathComponent(".openclaw/hooks.json")
        case .aider, .gemini, .goose, .generic: return nil
        }
    }

    /// True when the agent's config already contains the Harness notify hook.
    public static func isInstalled(agent: AgentKind, homeOverride: URL? = nil) -> Bool {
        guard let url = hookConfigURL(for: agent, homeOverride: homeOverride),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains(hookMarker)
    }

    /// Merge the agent's Harness hooks into its config (creating the file/dir if needed),
    /// preserving everything else. Idempotent. Throws `InstallError.unsupported` for agents
    /// without a hook integration.
    @discardableResult
    public static func install(agent: AgentKind, homeOverride: URL? = nil) throws -> InstallResult {
        guard let url = hookConfigURL(for: agent, homeOverride: homeOverride),
              let hook = hookPayload(for: agent)
        else { throw InstallError.unsupported(agent) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var merged: [String: Any] = hook
        var backedUp: URL?
        var replacedInvalidJSON = false
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("harness-bak-\(Int(Date().timeIntervalSince1970))")
            // Hard `try`: if we can't back the file up, abort before touching it — never risk
            // destroying a config we couldn't preserve first.
            try FileManager.default.copyItem(at: url, to: backup)
            backedUp = backup
            if let data = try? Data(contentsOf: url),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                merged = JSONMerge.deepMerge(existing, hook)
            } else {
                replacedInvalidJSON = true
            }
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return InstallResult(path: url, backedUp: backedUp, replacedInvalidJSON: replacedInvalidJSON)
    }

    // MARK: - Hook payloads

    /// Substring present in every Harness hook command — the `isInstalled` marker.
    private static let hookMarker = "harness-cli notify"

    private static func notifyCommand(title: String, body: String) -> String {
        "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"\(title)\" --body \"\(body)\""
    }

    private static func hookPayload(for agent: AgentKind) -> [String: Any]? {
        switch agent {
        case .claudeCode:
            return [
                "hooks": [
                    "Notification": [[
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": notifyCommand(title: "Claude Code", body: "$HARNESS_NOTIFY_MESSAGE"),
                        ]],
                    ]],
                    "Stop": [[
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": notifyCommand(title: "Claude Code", body: "Done"),
                        ]],
                    ]],
                ],
            ]
        case .codex:
            return [
                "hooks": [
                    "on_pause": notifyCommand(title: "Codex", body: "Awaiting input"),
                    "on_done": notifyCommand(title: "Codex", body: "Done"),
                ],
            ]
        case .cursor:
            return [
                "version": 1,
                "agent_notify": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Cursor\" --body \"$1\"",
            ]
        case .pi:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""]
        case .hermes:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""]
        case .openClaw:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""]
        case .aider, .gemini, .goose, .generic:
            return nil
        }
    }

    /// Resolve a CLI-style agent name (`claude`, `cursor-agent`, …) to an `AgentKind`.
    public static func resolveAgentName(_ raw: String) -> AgentKind? {
        switch raw.lowercased() {
        case "claude-code", "claude": return .claudeCode
        case "codex": return .codex
        case "cursor", "cursor-agent": return .cursor
        case "pi": return .pi
        case "hermes": return .hermes
        case "openclaw": return .openClaw
        default: return AgentKind(rawValue: raw.lowercased())
        }
    }
}
