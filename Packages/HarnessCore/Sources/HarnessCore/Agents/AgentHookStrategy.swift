import Foundation

/// How Harness writes one agent's hook config. Each installable `AgentKind` maps to exactly
/// one strategy (see `AgentHookInstaller.strategy(for:)`), which encapsulates the config file's
/// relative path plus its write semantics — JSON deep-merge, own-file overwrite, or in-place
/// text-region edit. This keeps `AgentHookInstaller.install` a single generic flow instead of a
/// per-agent pile of special cases, and lets each agent declare its *real* mechanism (researched
/// per tool; see `docs/agent-hooks/<agent>.md`) rather than forcing every agent into one shape.
enum AgentHookStrategy {
    /// Deep-merge an event/matcher JSON object — `{hooks:{Event:[{matcher,hooks:[{command}]}]}}`.
    /// Claude Code, Codex. `managedEvents` are pruned of Harness-owned entries before each merge
    /// so a re-install converges to the current payload instead of appending a second copy.
    case eventMatcherJSON(filename: String, payload: [String: Any], managedEvents: [String])

    /// Deep-merge a `{version, hooks:{event:[{command}]}}` JSON object — Cursor's shape, where
    /// each event maps to a flat array of `{command}` objects (no nested `matcher`/`hooks`).
    case eventArrayJSON(filename: String, payload: [String: Any], managedEvents: [String])

    /// Write a dedicated, Harness-owned JSON file verbatim — Grok's `~/.grok/hooks/harness.json`.
    /// We own the whole file (the agent merges every `*.json` in the dir), so install overwrites
    /// idempotently; there's nothing to prune or preserve.
    case ownJSONFile(filename: String, payload: [String: Any])

    /// Write a dedicated, Harness-owned text file verbatim — a JS plugin (OpenCode) or TS
    /// extension (Pi) auto-discovered from a plugins/extensions directory. Overwrite is idempotent.
    case ownTextFile(filename: String, contents: String)

    /// Upsert a sentinel-delimited, Harness-marked region into a text config that Harness doesn't
    /// own, editing it as text (never reserialized) so the surrounding file — comments, trailing
    /// commas, formatting — survives. `commentToken` is the config's line-comment marker (`#` for
    /// YAML, `//` for JSON5). `insertAtTop` puts the region just inside the root `{` (JSON5 object);
    /// otherwise it's appended at end-of-file (YAML's flat top-level keys). `conflictKey` is the
    /// top-level key the region introduces (e.g. `hooks`) — if the existing config already defines
    /// it (outside our region), the installer leaves the file untouched and asks the user to merge
    /// by hand rather than risk a duplicate-key corruption. Hermes, OpenClaw.
    case regionEdit(filename: String, body: String, commentToken: String, insertAtTop: Bool, conflictKey: String)

    /// The config file's path relative to the user's home directory.
    var filename: String {
        switch self {
        case let .eventMatcherJSON(filename, _, _),
             let .eventArrayJSON(filename, _, _),
             let .ownJSONFile(filename, _),
             let .ownTextFile(filename, _),
             let .regionEdit(filename, _, _, _, _):
            return filename
        }
    }
}
