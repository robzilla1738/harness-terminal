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
        // OpenCode notifies via process detection (no shell-command hook mechanism), like
        // Pi/Hermes rely on detection — so it has no installable hook file.
        case .openCode, .aider, .gemini, .goose, .generic: return nil
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
            let backup = backupURL(for: url)
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

        // Codex ignores its hooks file unless the hooks feature flag is enabled.
        if agent == .codex {
            try enableCodexHooksFeature(homeOverride: homeOverride)
        }
        return InstallResult(path: url, backedUp: backedUp, replacedInvalidJSON: replacedInvalidJSON)
    }

    /// Enable `[features] hooks = true` in `~/.codex/config.toml`, creating/editing it in
    /// place (backed up first) and idempotently. Codex only loads `~/.codex/hooks.json`
    /// when this flag is set. Mirrors the Skillz integration.
    private static func enableCodexHooksFeature(homeOverride: URL?) throws {
        let home = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".codex/config.toml")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if codexHooksFeatureEnabled(in: existing) { return }

        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        if let featuresIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) {
            var end = lines.count
            if let next = lines[(featuresIdx + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            }) { end = next }
            if let hooksIdx = lines[(featuresIdx + 1)..<end].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("hooks")
            }) {
                lines[hooksIdx] = "hooks = true"
            } else {
                lines.insert("hooks = true", at: featuresIdx + 1)
            }
        } else {
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append("[features]")
            lines.append("hooks = true")
        }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.copyItem(at: url, to: backupURL(for: url))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// A unique backup path for `url` (`<name>.harness-bak-<ms>-<rand>`). Millisecond
    /// timestamp + a short random suffix so backing the same file up twice in quick
    /// succession can't collide (a colliding `copyItem` would otherwise throw and abort).
    private static func backupURL(for url: URL) -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        return url.appendingPathExtension("harness-bak-\(stamp)-\(UUID().uuidString.prefix(8))")
    }

    /// True when `[features] hooks = true` is present in a `config.toml`'s contents.
    private static func codexHooksFeatureEnabled(in content: String) -> Bool {
        var inFeatures = false
        for raw in content.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inFeatures = (line == "[features]")
            } else if inFeatures, line.hasPrefix("hooks") {
                return line.contains("true")
            }
        }
        return false
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
            // Codex uses the same event/matcher hook shape as Claude Code (NOT `on_pause`/
            // `on_done`, which it ignores). It only reads these once `[features] hooks = true`
            // is set in `~/.codex/config.toml` — `install` enables that flag too.
            return [
                "hooks": [
                    "PermissionRequest": [[
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": notifyCommand(title: "Codex", body: "Awaiting input"),
                        ]],
                    ]],
                    "Stop": [[
                        "matcher": "*",
                        "hooks": [[
                            "type": "command",
                            "command": notifyCommand(title: "Codex", body: "Done"),
                        ]],
                    ]],
                ],
            ]
        case .cursor:
            return [
                "version": 1,
                "agent_notify": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Cursor\" --body \"$1\"",
                "agent_done": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Cursor\" --body \"Done\"",
            ]
        case .pi:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""]
        case .hermes:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""]
        case .openClaw:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\""]
        case .openCode, .aider, .gemini, .goose, .generic:
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
