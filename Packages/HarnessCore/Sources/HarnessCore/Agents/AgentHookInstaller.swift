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
                // Prune our own stale entries from the events we manage before merging, so a
                // re-install converges to exactly the current payload instead of appending a
                // second copy (JSONMerge unions arrays). This is what upgrades existing users
                // off the old broken `$HARNESS_NOTIFY_MESSAGE` command.
                merged = JSONMerge.deepMerge(pruneStaleHarnessHooks(existing, for: agent), hook)
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

    /// The event keys Harness writes into an event/matcher-shaped config (Claude Code, Codex).
    /// Other agents use flat keys (`notify`, `agent_notify`), which `deepMerge` overwrites
    /// scalar-wise, so they need no pruning.
    private static func managedHookEvents(for agent: AgentKind) -> [String] {
        switch agent {
        case .claudeCode: return ["Notification", "Stop"]
        case .codex: return ["PermissionRequest", "Stop"]
        default: return []
        }
    }

    /// Remove Harness-owned entries (command contains `hookMarker`) from the events we manage,
    /// dropping any event array left empty. Everything else — other keys, other events, and
    /// the user's own non-Harness entries within a managed event — is preserved untouched.
    /// Makes `install` idempotent and self-healing across command changes.
    private static func pruneStaleHarnessHooks(_ config: [String: Any], for agent: AgentKind) -> [String: Any] {
        let events = managedHookEvents(for: agent)
        guard !events.isEmpty, var hooks = config["hooks"] as? [String: Any] else { return config }

        for event in events {
            guard let entries = hooks[event] as? [Any] else { continue }
            let kept = entries.filter { entry in
                guard let entry = entry as? [String: Any],
                      let commands = entry["hooks"] as? [Any]
                else { return true } // shape we don't recognize — leave it alone
                let isHarnessOwned = commands.contains { command in
                    guard let command = (command as? [String: Any])?["command"] as? String
                    else { return false }
                    return command.contains(hookMarker)
                }
                return !isHarnessOwned
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }

        var result = config
        result["hooks"] = hooks
        return result
    }

    /// The installable agents that look present on this machine — any of the agent's known
    /// executables is on `$PATH`, or its config directory already exists. Used by onboarding to
    /// offer hook setup only for agents the user actually has (no nagging for absent ones).
    public static func detectInstalledAgents(homeOverride: URL? = nil, table: AgentTable = .default) -> [AgentKind] {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let fm = FileManager.default

        func isOnPath(_ executables: [String]) -> Bool {
            for dir in pathDirs {
                for exe in executables where fm.isExecutableFile(atPath: dir + "/" + exe) {
                    return true
                }
            }
            return false
        }
        func hasConfigDir(_ agent: AgentKind) -> Bool {
            guard let url = hookConfigURL(for: agent, homeOverride: homeOverride) else { return false }
            return fm.fileExists(atPath: url.deletingLastPathComponent().path)
        }

        return installableAgents.filter { agent in
            let executables = table.entries.first { $0.kind == agent }?.executables ?? []
            return isOnPath(executables) || hasConfigDir(agent)
        }
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

    /// A notify command whose body comes from the hook's stdin JSON `message` (`--from-hook`).
    /// Used for agents (Claude Code) that pass the notification text on stdin rather than as a
    /// shell argument — `--body "$HARNESS_NOTIFY_MESSAGE"` would expand to nothing.
    private static func notifyFromHookCommand(title: String) -> String {
        "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"\(title)\" --from-hook"
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
                            "command": notifyFromHookCommand(title: "Claude Code"),
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
        // Pi/Hermes/OpenClaw fire a single `notify` hook with no message argument, so pass a
        // `--title` to identify the agent on the banner (the body falls back to the default).
        case .pi:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Pi\""]
        case .hermes:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"Hermes\""]
        case .openClaw:
            return ["notify": "harness-cli notify --surface \"$HARNESS_SURFACE\" --title \"OpenClaw\""]
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
