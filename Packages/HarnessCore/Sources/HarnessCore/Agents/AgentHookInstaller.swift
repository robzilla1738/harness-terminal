import Foundation

/// Writes per-agent hook config files so each known agent CLI calls back into Harness via
/// `harness-cli notify --surface "$HARNESS_SURFACE"`. Hook commands prepend Harness's
/// app-support bin directory to PATH, so they keep working even when the user's agent
/// process did not load the shell profile that onboarding edits. Shared by the CLI (`install-hooks`)
/// and the Settings "Install hooks" button — UI-agnostic (no `print`/`exit`), so the GUI
/// can call it directly.
///
/// Each agent declares one `AgentHookStrategy` (see `strategy(for:)`) describing its *real* config
/// mechanism — JSON event/matcher merge (Claude Code, Codex), Cursor's `{version,hooks}` arrays, a
/// dedicated own-file (Grok JSON, OpenCode JS plugin, Pi TS extension), or an in-place YAML/JSON5
/// region edit (Hermes, OpenClaw). Existing files are always **backed up** before being touched and
/// never clobbered; merges/edits are idempotent. Re-installing also cleans up the orphaned files an
/// older Harness wrote at now-wrong paths (only when those files are Harness-owned). Per-agent
/// guides live in `docs/agent-hooks/<agent>.md`.
public enum AgentHookInstaller {
    public struct InstallResult: Sendable, Equatable {
        /// The config file that was written.
        public let path: URL
        /// The backup that was made of a pre-existing file, if any.
        public let backedUp: URL?
        /// True when the existing file wasn't valid JSON and was replaced (backup kept).
        public let replacedInvalidJSON: Bool
        /// Orphaned legacy hook files (from an older Harness, at now-wrong paths) we removed.
        public let removedLegacy: [URL]

        public init(path: URL, backedUp: URL?, replacedInvalidJSON: Bool, removedLegacy: [URL] = []) {
            self.path = path
            self.backedUp = backedUp
            self.replacedInvalidJSON = replacedInvalidJSON
            self.removedLegacy = removedLegacy
        }
    }

    public enum InstallError: Error, Equatable {
        /// `agent` has no hook integration (e.g. aider/gemini/goose/generic).
        case unsupported(AgentKind)
    }

    /// Agents Harness can install hooks for.
    public static let installableAgents: [AgentKind] = [
        .codex, .claudeCode, .cursor, .grok, .openCode, .pi, .hermes, .openClaw,
    ]

    public static func canInstall(_ agent: AgentKind) -> Bool {
        strategy(for: agent) != nil
    }

    /// The config file an agent's hooks live in, or nil when unsupported.
    public static func hookConfigURL(for agent: AgentKind, homeOverride: URL? = nil) -> URL? {
        guard let filename = strategy(for: agent)?.filename else { return nil }
        let home = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(filename)
    }

    /// True when the agent's config already contains the Harness notify hook. Works across every
    /// strategy because `hookMarker` is a literal substring of every command we write (JSON, JS,
    /// TS, YAML, or JSON5).
    public static func isInstalled(agent: AgentKind, homeOverride: URL? = nil) -> Bool {
        guard let url = hookConfigURL(for: agent, homeOverride: homeOverride),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains(hookMarker)
    }

    /// Install the agent's Harness hook in its real config file (creating dirs as needed),
    /// preserving everything else. Idempotent. Throws `InstallError.unsupported` for agents
    /// without a hook integration.
    @discardableResult
    public static func install(agent: AgentKind, homeOverride: URL? = nil) throws -> InstallResult {
        guard let strategy = strategy(for: agent) else { throw InstallError.unsupported(agent) }
        let home = homeOverride ?? FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(strategy.filename)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var backedUp: URL?
        var replacedInvalidJSON = false
        switch strategy {
        case let .eventMatcherJSON(_, payload, managedEvents):
            (backedUp, replacedInvalidJSON) = try mergeJSON(at: url, payload: payload) {
                pruneStaleHarnessHooks($0, events: managedEvents)
            }
        case let .eventArrayJSON(_, payload, managedEvents):
            (backedUp, replacedInvalidJSON) = try mergeJSON(at: url, payload: payload) {
                pruneCursorHooks($0, events: managedEvents)
            }
        case let .ownJSONFile(_, payload):
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            backedUp = try writeOwnFile(at: url, data: data)
        case let .ownTextFile(_, contents):
            backedUp = try writeOwnFile(at: url, data: Data(contents.utf8))
        case let .yamlEdit(_, body):
            backedUp = try upsertRegion(at: url, commentToken: "#", body: body, insertAtTop: false)
        case let .json5Edit(_, body):
            backedUp = try upsertRegion(at: url, commentToken: "//", body: body, insertAtTop: true)
        }

        let removedLegacy = try removeLegacyHookFiles(for: agent, home: home)
        return InstallResult(path: url, backedUp: backedUp, replacedInvalidJSON: replacedInvalidJSON, removedLegacy: removedLegacy)
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

    // MARK: - Strategy table

    /// Each installable agent's real hook mechanism. Returns nil for agents Harness only detects
    /// (aider/gemini/goose) and `.generic`.
    static func strategy(for agent: AgentKind) -> AgentHookStrategy? {
        switch agent {
        case .claudeCode:
            return .eventMatcherJSON(filename: ".claude/settings.json",
                                     payload: claudePayload, managedEvents: ["Notification", "Stop"])
        case .codex:
            // Codex reads the same event/matcher shape as Claude Code from `~/.codex/hooks.json`,
            // and hooks are enabled by default now (the old `[features] hooks = true` flag only
            // *disables* them), so we no longer touch `config.toml`.
            return .eventMatcherJSON(filename: ".codex/hooks.json",
                                     payload: codexPayload, managedEvents: ["PermissionRequest", "Stop", "Notification"])
        case .cursor:
            // Real Cursor hooks: `~/.cursor/hooks.json`, `{version,hooks:{stop:[{command}]}}`.
            return .eventArrayJSON(filename: ".cursor/hooks.json",
                                   payload: cursorPayload, managedEvents: ["stop"])
        case .grok:
            // Grok Build merges every `~/.grok/hooks/*.json`, so we own a dedicated file.
            return .ownJSONFile(filename: ".grok/hooks/harness.json", payload: grokPayload)
        case .openCode:
            // OpenCode auto-loads JS/TS plugins from its global plugins dir.
            return .ownTextFile(filename: ".config/opencode/plugins/harness.js", contents: openCodePlugin)
        case .pi:
            // Pi auto-discovers TS extensions from `~/.pi/agent/extensions/*.ts` (no config edit).
            return .ownTextFile(filename: ".pi/agent/extensions/harness.ts", contents: piExtension)
        case .hermes:
            // Hermes declares shell hooks in `~/.hermes/config.yaml` (consent via `hermes hooks`).
            return .yamlEdit(filename: ".hermes/config.yaml", body: hermesHookBody)
        case .openClaw:
            // OpenClaw reads a JSON5 config; edit as text to preserve comments/trailing commas.
            return .json5Edit(filename: ".openclaw/openclaw.json", body: openClawHookBody)
        case .aider, .gemini, .goose, .generic:
            return nil
        }
    }

    // MARK: - JSON merge strategies

    /// Deep-merge `payload` into the JSON object at `url`, backing the file up first and running
    /// `prune` over any existing object so re-installs converge instead of appending duplicates.
    /// Returns whether a backup was made and whether an unparseable file was replaced.
    private static func mergeJSON(
        at url: URL,
        payload: [String: Any],
        prune: ([String: Any]) -> [String: Any]
    ) throws -> (backedUp: URL?, replacedInvalidJSON: Bool) {
        var merged: [String: Any] = payload
        var backedUp: URL?
        var replacedInvalidJSON = false
        if FileManager.default.fileExists(atPath: url.path) {
            // Hard `try`: if we can't back the file up, abort before touching it — never risk
            // destroying a config we couldn't preserve first.
            backedUp = try backUp(url)
            if let data = try? Data(contentsOf: url),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                merged = JSONMerge.deepMerge(prune(existing), payload)
            } else {
                replacedInvalidJSON = true
            }
        }
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return (backedUp, replacedInvalidJSON)
    }

    /// Remove Harness-owned entries (command contains `hookMarker`) from the event/matcher-shaped
    /// `events` we manage, dropping any event array left empty. Everything else — other keys, other
    /// events, and the user's own non-Harness entries within a managed event — is preserved.
    private static func pruneStaleHarnessHooks(_ config: [String: Any], events: [String]) -> [String: Any] {
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

    /// Cursor's events map to flat arrays of `{command}` objects (no nested `hooks`). Drop the
    /// Harness-owned entries from the managed `events`, preserving the user's own.
    private static func pruneCursorHooks(_ config: [String: Any], events: [String]) -> [String: Any] {
        guard !events.isEmpty, var hooks = config["hooks"] as? [String: Any] else { return config }
        for event in events {
            guard let entries = hooks[event] as? [Any] else { continue }
            let kept = entries.filter { entry in
                guard let command = (entry as? [String: Any])?["command"] as? String else { return true }
                return !command.contains(hookMarker)
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        var result = config
        result["hooks"] = hooks
        return result
    }

    // MARK: - Own-file & text-region strategies

    /// Overwrite a Harness-owned file (e.g. `harness.json`/`harness.js`/`harness.ts`) atomically,
    /// backing up any pre-existing copy first. Idempotent: we own the whole file.
    private static func writeOwnFile(at url: URL, data: Data) throws -> URL? {
        var backedUp: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            backedUp = try backUp(url)
        }
        try data.write(to: url, options: .atomic)
        return backedUp
    }

    /// Upsert a sentinel-delimited managed region into a text config, backing it up first.
    /// `insertAtTop` inserts the region just inside the first `{` (JSON5 root object); otherwise
    /// the region is appended at end-of-file (YAML). On reinstall the existing region is replaced
    /// in place, so the edit is idempotent and the surrounding file — including comments — survives.
    private static func upsertRegion(at url: URL, commentToken: String, body: String, insertAtTop: Bool) throws -> URL? {
        let begin = "\(commentToken) >>> harness-managed (do not edit) >>>"
        let end = "\(commentToken) <<< harness-managed <<<"
        let region = "\(begin)\n\(body)\n\(end)"

        var backedUp: URL?
        var text = ""
        if FileManager.default.fileExists(atPath: url.path) {
            backedUp = try backUp(url)
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }

        if let beginRange = text.range(of: begin), let endRange = text.range(of: end), beginRange.lowerBound < endRange.lowerBound {
            // Replace the existing managed region in place.
            text.replaceSubrange(beginRange.lowerBound..<endRange.upperBound, with: region)
        } else if insertAtTop {
            if let brace = text.firstIndex(of: "{") {
                // Insert just inside the existing root object.
                text.insert(contentsOf: "\n\(region)\n", at: text.index(after: brace))
            } else {
                // No root object yet (fresh/empty config) — create one around the region.
                text = "{\n\(region)\n}\n"
            }
        } else {
            // YAML: append the region at end-of-file (multiple top-level keys are valid).
            if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
            text += "\(region)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return backedUp
    }

    // MARK: - Legacy cleanup

    /// Paths an older Harness wrote hooks to before we moved each agent to its real config file.
    /// On install we remove these orphans so a stale, non-firing hook doesn't linger — but only
    /// when the file is Harness-owned, never a user file that happens to sit at the old path.
    private static func legacyHookFiles(for agent: AgentKind, home: URL) -> [URL] {
        let relative: [String]
        switch agent {
        case .cursor: relative = [".cursor/agent-hooks.json"]
        case .pi: relative = [".pi/hooks.json"]
        case .hermes: relative = [".hermes/hooks.json"]
        case .openClaw: relative = [".openclaw/hooks.json"]
        default: relative = []
        }
        return relative.map { home.appendingPathComponent($0) }
    }

    private static func removeLegacyHookFiles(for agent: AgentKind, home: URL) throws -> [URL] {
        var removed: [URL] = []
        for url in legacyHookFiles(for: agent, home: home) {
            guard FileManager.default.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains(hookMarker)
            else { continue } // absent or a user file — leave it alone
            _ = try? backUp(url)
            try FileManager.default.removeItem(at: url)
            removed.append(url)
        }
        return removed
    }

    // MARK: - Backups

    /// Copy `url` to a unique backup path (`<name>.harness-bak-<ms>-<rand>`) and return it.
    /// Millisecond timestamp + short random suffix so backing the same file up twice in quick
    /// succession can't collide.
    @discardableResult
    private static func backUp(_ url: URL) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let backup = url.appendingPathExtension("harness-bak-\(stamp)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    // MARK: - Hook commands

    /// Substring present in every Harness hook command — the `isInstalled` marker.
    private static let hookMarker = "harness-cli notify"
    private static let notifyPrefix = "PATH=\"$HOME/Library/Application Support/Harness/bin:$PATH\" harness-cli notify"

    private static func notifyCommand(title: String, body: String) -> String {
        "\(notifyPrefix) --surface \"$HARNESS_SURFACE\" --title \"\(title)\" --body \"\(body)\""
    }

    /// A notify command whose body comes from the hook's stdin JSON `message` (`--from-hook`).
    /// Used for agents (Claude Code) that pass the notification text on stdin rather than as a
    /// shell argument — `--body "$HARNESS_NOTIFY_MESSAGE"` would expand to nothing.
    private static func notifyFromHookCommand(title: String) -> String {
        "\(notifyPrefix) --surface \"$HARNESS_SURFACE\" --title \"\(title)\" --from-hook"
    }

    // MARK: - Per-agent payloads

    private static var claudePayload: [String: Any] {
        [
            "hooks": [
                "Notification": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": notifyFromHookCommand(title: "Claude Code")]],
                ]],
                "Stop": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": notifyCommand(title: "Claude Code", body: "Done")]],
                ]],
            ],
        ]
    }

    private static var codexPayload: [String: Any] {
        [
            "hooks": [
                "PermissionRequest": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": notifyCommand(title: "Codex", body: "Awaiting input")]],
                ]],
                "Notification": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": notifyCommand(title: "Codex", body: "Notification")]],
                ]],
                "Stop": [[
                    "matcher": "*",
                    "hooks": [["type": "command", "command": notifyCommand(title: "Codex", body: "Done")]],
                ]],
            ],
        ]
    }

    private static var cursorPayload: [String: Any] {
        [
            "version": 1,
            "hooks": [
                "stop": [["command": notifyCommand(title: "Cursor", body: "Done")]],
            ],
        ]
    }

    private static var grokPayload: [String: Any] {
        [
            "on-complete": notifyCommand(title: "Grok", body: "Done"),
            "on-error": notifyCommand(title: "Grok", body: "Error"),
        ]
    }

    /// OpenCode plugin: surfaces session-idle / permission events in Harness via Bun's `$` shell.
    /// Contains `harness-cli notify`, so `isInstalled` detects it.
    private static var openCodePlugin: String {
        """
        // harness-managed — surfaces OpenCode session events in Harness. Safe to delete.
        export const HarnessNotify = async ({ $ }) => ({
          "session.idle": async () => {
            await $`\(notifyPrefix) --surface ${process.env.HARNESS_SURFACE} --title OpenCode --body Done`
          },
          "permission.asked": async () => {
            await $`\(notifyPrefix) --surface ${process.env.HARNESS_SURFACE} --title OpenCode --body "Awaiting input"`
          },
        })
        """
    }

    /// Pi extension: runs the notify command when a session ends. Auto-discovered from
    /// `~/.pi/agent/extensions/*.ts`. Contains `harness-cli notify`, so `isInstalled` detects it.
    private static var piExtension: String {
        """
        // harness-managed — surfaces Pi session events in Harness. Safe to delete.
        import { execSync } from "node:child_process"

        export function activate(api: any) {
          const notify = (body: string) =>
            execSync(
              `\(notifyPrefix) --surface "${process.env.HARNESS_SURFACE}" --title "Pi" --body "${body}"`,
              { stdio: "ignore" }
            )
          api.on?.("session_end", () => notify("Done"))
          api.on?.("stop", () => notify("Done"))
        }
        """
    }

    /// Hermes YAML hook block (inside a sentinel region appended to `~/.hermes/config.yaml`).
    /// Inert until approved with `hermes hooks` (writes `~/.hermes/shell-hooks-allowlist.json`).
    private static var hermesHookBody: String {
        """
        hooks:
          - event: stop
            command: '\(notifyCommand(title: "Hermes", body: "Done"))'
        """
    }

    /// OpenClaw JSON5 hook block (inserted just inside the root object of `~/.openclaw/openclaw.json`).
    private static var openClawHookBody: String {
        """
        "hooks": {
          "harness-notify": {
            "command": "\(escapedForJSON(notifyCommand(title: "OpenClaw", body: "Done")))",
          },
        },
        """
    }

    /// Escape a command for embedding inside a double-quoted JSON5 string literal.
    private static func escapedForJSON(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Resolve a CLI-style agent name (`claude`, `cursor-agent`, …) to an `AgentKind`.
    public static func resolveAgentName(_ raw: String) -> AgentKind? {
        switch raw.lowercased() {
        case "claude-code", "claude": return .claudeCode
        case "codex": return .codex
        case "cursor", "cursor-agent": return .cursor
        case "grok", "grok-build", "grok-cli": return .grok
        case "pi": return .pi
        case "hermes": return .hermes
        case "openclaw": return .openClaw
        default: return AgentKind(rawValue: raw.lowercased())
        }
    }
}
