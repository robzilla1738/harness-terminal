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
        /// True when the existing file wasn't valid/readable and was replaced (backup kept).
        public let replacedInvalidJSON: Bool
        /// Orphaned legacy hook files (from an older Harness, at now-wrong paths) we removed.
        public let removedLegacy: [URL]
        /// True when an existing structured config (Hermes YAML / OpenClaw JSON5) already defines
        /// the key we'd write, or is too malformed to edit safely — so we left it **untouched**
        /// and the user must merge the hook in by hand (see the agent's doc). `path`/`isInstalled`
        /// will not reflect a Harness hook in this case.
        public let needsManualMerge: Bool

        public init(
            path: URL, backedUp: URL?, replacedInvalidJSON: Bool,
            removedLegacy: [URL] = [], needsManualMerge: Bool = false
        ) {
            self.path = path
            self.backedUp = backedUp
            self.replacedInvalidJSON = replacedInvalidJSON
            self.removedLegacy = removedLegacy
            self.needsManualMerge = needsManualMerge
        }
    }

    public enum InstallError: Error, Equatable {
        /// `agent` has no hook integration (e.g. aider/gemini/goose/generic).
        case unsupported(AgentKind)
    }

    /// Agents Harness can install hooks for — derived from the strategy table (single source of
    /// truth) so it can never drift from `canInstall`/`install`. Enum-declaration order.
    public static let installableAgents: [AgentKind] = AgentKind.allCases.filter { strategy(for: $0) != nil }

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
        var needsManualMerge = false
        switch strategy {
        case let .eventMatcherJSON(_, payload, managedEvents):
            (backedUp, replacedInvalidJSON) = try mergeJSON(at: url, payload: payload) {
                pruneHooks($0, events: managedEvents, isHarnessOwned: isEventMatcherEntryHarnessOwned)
            }
        case let .eventArrayJSON(_, payload, managedEvents):
            (backedUp, replacedInvalidJSON) = try mergeJSON(at: url, payload: payload) {
                pruneHooks($0, events: managedEvents, isHarnessOwned: isFlatEntryHarnessOwned)
            }
        case let .ownJSONFile(_, payload):
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            backedUp = try writeOwnFile(at: url, data: data)
        case let .ownTextFile(_, contents):
            backedUp = try writeOwnFile(at: url, data: Data(contents.utf8))
        case let .regionEdit(_, body, commentToken, insertAtTop, conflictKey):
            (backedUp, replacedInvalidJSON, needsManualMerge) = try upsertRegion(
                at: url, commentToken: commentToken, body: body,
                insertAtTop: insertAtTop, conflictKey: conflictKey)
        }

        // Don't migrate-away the old file while the new one wasn't written (manual-merge case) —
        // the user would lose both their working hook and the orphan cleanup signal.
        let removedLegacy = needsManualMerge ? [] : try removeLegacyHookFiles(for: agent, home: home)
        return InstallResult(
            path: url, backedUp: backedUp, replacedInvalidJSON: replacedInvalidJSON,
            removedLegacy: removedLegacy, needsManualMerge: needsManualMerge)
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

    /// A self-contained instruction a user can paste into ANY coding agent / IDE running on their
    /// Mac to have it wire up its own Harness hook — the escape hatch for when one-click install
    /// can't reach a tool, or the user wants the agent to do it. Generated from the live strategy
    /// table, so every path it cites matches exactly what `install` would write.
    public static var setupPrompt: String {
        let rows = installableAgents.map { kind -> String in
            let rel = strategy(for: kind)?.filename ?? ""
            return "  • \(kind.displayName): `harness-cli install-hooks \(kind.rawValue)`  (config: ~/\(rel))"
        }.joined(separator: "\n")

        return """
        Set up Harness terminal notifications for the coding agent you are running inside (macOS). \
        Goal: when you finish a turn or need my input, call Harness so it surfaces you in its \
        menu-bar notch.

        Preferred — Harness ships a CLI at "$HOME/Library/Application Support/Harness/bin/harness-cli". \
        If it exists, run its installer for whichever tool you are (it writes the correct hook \
        config for that tool and backs up any existing file first):

        \(rows)

        If that CLI is NOT installed, create the hook config yourself at the path listed above for \
        your tool, and have it run this exact command (this is what notifies Harness):

          PATH="$HOME/Library/Application Support/Harness/bin:$PATH" harness-cli notify --surface "$HARNESS_SURFACE" --title "<your tool name>" --body "Done"

        $HARNESS_SURFACE is exported by Harness for every pane, so the notification reaches the right \
        tab. Always back up a file before editing it, then tell me which file you changed.
        """
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
            return .regionEdit(filename: ".hermes/config.yaml", body: hermesHookBody,
                               commentToken: "#", insertAtTop: false, conflictKey: "hooks")
        case .openClaw:
            // OpenClaw reads a JSON5 config; edit as text to preserve comments/trailing commas.
            return .regionEdit(filename: ".openclaw/openclaw.json", body: openClawHookBody,
                               commentToken: "//", insertAtTop: true, conflictKey: "hooks")
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

    /// Drop the Harness-owned entries (per `isHarnessOwned`) from the `hooks[event]` arrays we
    /// manage, removing any event left empty. Everything else — other keys, other events, and the
    /// user's own non-Harness entries within a managed event — is preserved. Makes re-install
    /// converge to exactly the current payload instead of appending a duplicate. The two hook
    /// shapes Harness writes (Claude/Codex nested `{matcher,hooks:[{command}]}` and Cursor flat
    /// `{command}`) differ only in this predicate.
    private static func pruneHooks(
        _ config: [String: Any], events: [String],
        isHarnessOwned: ([String: Any]) -> Bool
    ) -> [String: Any] {
        guard !events.isEmpty, var hooks = config["hooks"] as? [String: Any] else { return config }
        for event in events {
            guard let entries = hooks[event] as? [Any] else { continue }
            let kept = entries.filter { entry in
                guard let entry = entry as? [String: Any] else { return true } // unknown shape — keep
                return !isHarnessOwned(entry)
            }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        var result = config
        result["hooks"] = hooks
        return result
    }

    /// Event/matcher shape (Claude Code, Codex): Harness-owned if any of `entry["hooks"]`'s
    /// commands contains the marker.
    private static func isEventMatcherEntryHarnessOwned(_ entry: [String: Any]) -> Bool {
        guard let commands = entry["hooks"] as? [Any] else { return false }
        return commands.contains { command in
            guard let text = (command as? [String: Any])?["command"] as? String else { return false }
            return text.contains(hookMarker)
        }
    }

    /// Flat shape (Cursor): Harness-owned if the entry's own `command` contains the marker.
    private static func isFlatEntryHarnessOwned(_ entry: [String: Any]) -> Bool {
        (entry["command"] as? String)?.contains(hookMarker) ?? false
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

    /// Upsert a sentinel-delimited managed region into a text config we don't own, backing it up
    /// first. On reinstall the existing region is replaced in place (idempotent); on first install
    /// the region is inserted just inside the root `{` (JSON5) or appended at end-of-file (YAML),
    /// preserving the surrounding file including comments.
    ///
    /// Refuses to edit — returning `needsManualMerge` and leaving the file **untouched** — when it
    /// can't do so safely: the config already defines `conflictKey` outside our region (a duplicate
    /// would corrupt it), exactly one sentinel survives (a torn region we can't locate), or a
    /// JSON5 file has no balanced root object to insert into. `replacedInvalidJSON` is surfaced
    /// when an existing file couldn't be read as text (its bytes are preserved in the backup).
    private static func upsertRegion(
        at url: URL, commentToken: String, body: String, insertAtTop: Bool, conflictKey: String
    ) throws -> (backedUp: URL?, replacedInvalidJSON: Bool, needsManualMerge: Bool) {
        let begin = "\(commentToken) >>> harness-managed (do not edit) >>>"
        let end = "\(commentToken) <<< harness-managed <<<"
        let region = "\(begin)\n\(body)\n\(end)"

        let exists = FileManager.default.fileExists(atPath: url.path)
        var replacedInvalid = false
        var text = ""
        if exists {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                text = s
            } else {
                replacedInvalid = true // unreadable as text — we'll write fresh; bytes kept in backup
            }
        }

        let beginRange = text.range(of: begin)
        let endRange = text.range(of: end)

        var result = text
        if let b = beginRange, let e = endRange, b.lowerBound < e.lowerBound {
            // Replace the existing managed region in place.
            result.replaceSubrange(b.lowerBound..<e.upperBound, with: region)
        } else if (beginRange == nil) != (endRange == nil) {
            // Exactly one sentinel present — a torn region we can't safely locate. Don't guess.
            return (nil, false, true)
        } else if !replacedInvalid, definesKey(conflictKey, in: text, insertAtTop: insertAtTop) {
            // The config already defines our key — a second one would corrupt it. Leave it alone.
            return (nil, false, true)
        } else if insertAtTop {
            // `result` still equals `text` here, so the index is valid for `result`.
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = "{\n\(region)\n}\n"
            } else if let brace = rootBraceIndex(in: result), result[brace...].contains(where: { $0 == "}" }) {
                result.insert(contentsOf: "\n\(region)\n", at: result.index(after: brace))
            } else {
                // Non-empty but no balanced root object to insert into — don't risk corrupting it.
                return (nil, false, true)
            }
        } else {
            // YAML: append the region at end-of-file (multiple top-level keys are valid).
            if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            result += "\(region)\n"
        }

        let backedUp = exists ? try backUp(url) : nil
        try result.write(to: url, atomically: true, encoding: .utf8)
        return (backedUp, replacedInvalid, false)
    }

    /// True if `text` defines top-level `key` outside any Harness region. For JSON5 we accept a
    /// quoted or bare key followed by `:`; for YAML a line starting at column 0 with `key:`. This
    /// is deliberately conservative — a false positive only downgrades us to "merge manually",
    /// never a corrupting edit.
    private static func definesKey(_ key: String, in text: String, insertAtTop: Bool) -> Bool {
        if insertAtTop {
            // JSON5: `"key"` or `key` followed by optional space then `:`.
            for variant in ["\"\(key)\"", key] {
                var search = text.startIndex
                while let r = text.range(of: variant, range: search..<text.endIndex) {
                    let after = text[r.upperBound...].drop { $0 == " " || $0 == "\t" }
                    if after.first == ":" { return true }
                    search = r.upperBound
                }
            }
            return false
        } else {
            // YAML top-level key: a line (column 0, unindented) beginning `key:`.
            return text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
                guard let first = line.first, first != " ", first != "\t" else { return false }
                return line.hasPrefix("\(key):")
            }
        }
    }

    /// Index of the JSON5 root object's opening brace, skipping leading whitespace and `//` /
    /// `/* */` comments so a brace inside a header comment (e.g. `// see { docs }`) is never
    /// mistaken for the root. Returns nil if no structural `{` is found.
    private static func rootBraceIndex(in text: String) -> String.Index? {
        var i = text.startIndex
        let end = text.endIndex
        while i < end {
            let c = text[i]
            if c == "{" { return i }
            let afterI = text.index(after: i)
            if c == "/", afterI < end {
                switch text[afterI] {
                case "/": // line comment — skip to end of line
                    while i < end, text[i] != "\n" { i = text.index(after: i) }
                    continue
                case "*": // block comment — skip past the closing */
                    i = text.index(i, offsetBy: 2, limitedBy: end) ?? end
                    while i < end {
                        let next = text.index(after: i)
                        if text[i] == "*", next < end, text[next] == "/" {
                            i = text.index(after: next)
                            break
                        }
                        i = text.index(after: i)
                    }
                    continue
                default:
                    break
                }
            }
            i = afterI
        }
        return nil
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
            // Never delete without a recoverable backup. If the backup fails, keep the orphan.
            guard (try? backUp(url)) != nil else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url)
            }
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
            await $`\(notifyPrefix) --surface "${process.env.HARNESS_SURFACE ?? ""}" --title OpenCode --body Done`
          },
          "permission.asked": async () => {
            await $`\(notifyPrefix) --surface "${process.env.HARNESS_SURFACE ?? ""}" --title OpenCode --body "Awaiting input"`
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
              `\(notifyPrefix) --surface "${process.env.HARNESS_SURFACE ?? ""}" --title "Pi" --body "${body}"`,
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
