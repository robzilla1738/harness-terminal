import Foundation

/// Scoped, typed options. Reads short-circuit on the first scope that has a
/// value, falling back through `pane → tab → session → workspace → global` so
/// users can `set-option -g status on` once and override per-tab with
/// `set-option -t <tabID> status off`.
///
/// The store persists to `options.json` on every mutation. Defaults live in
/// `OptionStore.builtinDefaults` so a fresh install still has reasonable
/// values without writing a giant file out of the box.
public final class OptionStore: @unchecked Sendable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case pane, tab, session, workspace, global
    }

    public struct ScopedKey: Hashable, Codable, Sendable {
        public let scope: Scope
        public let target: String? // nil for global; UUID/string for others
        public let key: String
        public init(scope: Scope, target: String? = nil, key: String) {
            self.scope = scope
            self.target = target
            self.key = key
        }
    }

    public enum Value: Codable, Sendable, Equatable {
        case bool(Bool)
        case int(Int)
        case string(String)
    }

    private var values: [String: Value] = [:]
    private let url: URL
    private let lock = NSLock()
    // Debounced write — mirrors SessionStore.scheduleSave. Mutations mark dirty by enqueuing a
    // coalesced write; only the last mutation in a burst actually hits the disk. `saveQueue`
    // serializes disk writes independently of `lock` so the mutation path never blocks on I/O.
    private let saveQueue = DispatchQueue(label: "com.robert.harness.option-store-save")
    private var pendingSave: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.15

    public init(url: URL? = nil) {
        self.url = url ?? HarnessPaths.applicationSupport.appendingPathComponent("options.json")
        self.values = Self.load(url: self.url)
        if values.isEmpty {
            // Seed defaults so the first read returns something sensible.
            for (key, value) in Self.builtinDefaults {
                let id = Self.encodeKey(ScopedKey(scope: .global, key: key))
                values[id] = value
            }
            save()
        } else if Self.migrateSupersededDefaults(&values) {
            // Old saved values that exactly match a shipped-then-replaced default
            // get upgraded in place. User customizations (anything not in the
            // superseded list) are left alone.
            save()
        }
    }

    /// tmux option-name aliases mapped onto the Harness option they correspond to.
    /// `default-terminal` would set TERM in tmux; Harness pins TERM and exposes the
    /// terminal-identity option (TERM_PROGRAM/XTVERSION) as the adjustable identity.
    private static let keyAliases: [String: String] = [
        "default-terminal": TerminalIdentity.optionKey,
    ]
    private static func canonical(_ key: String) -> String { keyAliases[key] ?? key }

    /// Recognized option names beyond `builtinDefaults`: options Harness reads but doesn't seed a
    /// default for (`status-center`, the per-row `status-format-<N>`), plus real tmux options
    /// Harness accepts for `.tmux.conf` compatibility even when not yet honored (so migrating a
    /// config doesn't hard-fail). A name that is neither here, in `builtinDefaults`/`keyAliases`,
    /// nor `@`-prefixed is a typo or an unsupported invention and is rejected by `set-option`.
    private static let additionalRecognizedKeys: Set<String> = [
        // Implemented but unseeded (no global default; written per-tab by the sync-panes toggle).
        "synchronize-panes",
        // Read but intentionally unseeded (empty default).
        "status-center",
        // Common tmux options Harness recognizes but does not yet fully honor — accepted so a
        // real `.tmux.conf` migrates without a loud failure (tracked on the parity roadmap).
        "status-interval", "status-justify", "status-keys", "status-style", "status-bg", "status-fg",
        "message-style", "message-command-style", "mode-style",
        "window-status-style", "window-status-current-style", "window-status-format",
        "window-status-current-format", "window-status-separator", "window-status-activity-style",
        "pane-border-style", "pane-active-border-style", "display-panes-time", "display-panes-colour",
        "word-separators", "wrap-search", "aggressive-resize", "destroy-unattached",
        "visual-bell", "visual-activity", "visual-silence", "bell-action", "activity-action",
        "silence-action", "escape-time", "focus-events", "default-shell", "default-command",
        "default-size", "set-titles-string", "assume-paste-time", "cursor-style",
    ]

    /// Whether `key` is a settable option: a known Harness/tmux option name, or a `@`-prefixed user
    /// option (always allowed — arbitrary user storage). Drives `set-option`'s loud rejection of
    /// unknown keys, so a typo like `moused` fails instead of being silently stored and never read.
    public static func isRecognizedOptionKey(_ rawKey: String) -> Bool {
        if rawKey.hasPrefix("@") { return rawKey.count > 1 } // user option (must name something)
        let key = canonical(rawKey)
        if builtinDefaults[key] != nil || keyAliases[rawKey] != nil { return true }
        if additionalRecognizedKeys.contains(key) { return true }
        // Per-row status format (`status-format-0`, `status-format-1`, …).
        if key.hasPrefix("status-format-"), Int(key.dropFirst("status-format-".count)) != nil { return true }
        return false
    }

    public func get(_ rawKey: String, scope: Scope = .global, target: String? = nil) -> Value? {
        let key = Self.canonical(rawKey)
        lock.lock(); defer { lock.unlock() }
        // Walk scopes from most specific to global.
        let preferred = ScopedKey(scope: scope, target: target, key: key)
        if let v = values[Self.encodeKey(preferred)] { return v }
        // Inheritance fallback: try less-specific scopes for the same key.
        for s in Self.fallbackOrder(from: scope) {
            let candidate = ScopedKey(scope: s, target: nil, key: key)
            if let v = values[Self.encodeKey(candidate)] { return v }
        }
        return Self.builtinDefaults[key]
    }

    public func set(_ value: Value, key rawKey: String, scope: Scope = .global, target: String? = nil) {
        let key = Self.canonical(rawKey)
        lock.lock()
        values[Self.encodeKey(ScopedKey(scope: scope, target: target, key: key))] = value
        lock.unlock()
        save()
    }

    public func unset(key rawKey: String, scope: Scope = .global, target: String? = nil) {
        // Same alias mapping as get/set — unsetting `default-terminal` must clear
        // the canonical key, not leave the stored value reachable by both names.
        let key = Self.canonical(rawKey)
        lock.lock()
        values.removeValue(forKey: Self.encodeKey(ScopedKey(scope: scope, target: target, key: key)))
        lock.unlock()
        save()
    }

    /// Remove every option stored at exactly (`scope`, `target`) — the teardown GC for
    /// target-scoped values (pane options die with their surface, etc.); without it the
    /// store grows without bound as targets churn. No-op (no save) when nothing matches.
    public func removeAll(scope: Scope, target: String?) {
        lock.lock()
        let before = values.count
        values = values.filter { id, _ in
            guard let key = Self.decodeKey(id) else { return true }
            return key.scope != scope || key.target != target
        }
        let changed = values.count != before
        lock.unlock()
        if changed { save() }
    }

    public func snapshot(scope: Scope? = nil) -> [(ScopedKey, Value)] {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { id, value in
            guard let key = Self.decodeKey(id) else { return nil }
            if let scope, key.scope != scope { return nil }
            return (key, value)
        }
    }

    // MARK: Defaults

    /// Reasonable starting values. Each option key has a documented purpose
    /// and is expected to be readable by exactly one consumer (status line,
    /// mouse handler, etc.).
    public static let builtinDefaults: [String: Value] = [
        "status": .bool(true),
        "status-position": .string("bottom"),
        "status-left": .string(" #{workspace_name}#{?session_name, · #{session_name},} "),
        "status-right": .string(" #{cwd_basename}#{?git_branch, · #{git_branch},} · #{time:%H:%M} "),
        "mouse": .bool(true),
        "mode-keys": .string("vi"),
        "set-clipboard": .bool(true),
        "history-limit": .int(10_000),
        // Index of the first window / pane in `-t session:window.pane` targets and
        // in display (`#{window_index}`, `#{pane_index}`, display-panes numbers).
        // Default 0 (array-aligned); set to 1 for tmux's common `base-index 1`.
        "base-index": .int(0),
        "pane-base-index": .int(0),
        // When on, tab indices are renumbered contiguously after a tab closes.
        "renumber-windows": .bool(false),
        // One-shot first-run / what's-new terminal banner — read by the daemon's
        // `injectVersionBannerIfPending`. Off suppresses the output but still records
        // the build as seen (the banner never resurrects when re-enabled).
        "update-banner": .bool(true),
        // Title behavior: `allow-rename` (global) lets a program set the title via
        // OSC; `automatic-rename` (per-tab, defaults on) is turned off by a manual
        // `rename-tab` so the chosen name sticks.
        "allow-rename": .bool(true),
        "automatic-rename": .bool(true),
        // Monitoring (Phase 5) — read by the daemon's per-surface output monitor. `activity`
        // flags a non-current window on output (`#`); `silence` flags it after N seconds of no
        // output (0 = off, `~`); `bell` flags it on a terminal bell (`!`).
        "monitor-activity": .bool(false),
        "monitor-silence": .int(0),
        "monitor-bell": .bool(true),
        // Pane base styles (`fg=…,bg=…`) — read by the GUI (`TerminalHostView`) and the ssh
        // compositor (`WindowAttachClient`) via `PaneStyle`/`PaneStyleSet`. Empty = no
        // override (theme canvas). `window-active-style fg=default,bg=default` cancels a dim
        // set by `window-style` on the active pane (the classic dim-inactive-panes setup).
        "window-style": .string(""),
        "window-active-style": .string(""),
        "pane-style": .string(""),
        "pane-active-style": .string(""),
        // `pane-border-status` (`off`/`top`/`bottom`) draws a `pane-border-format` label on a
        // row carved from each pane's border. Read by the GUI (`TerminalHostView`) and the ssh
        // compositor (`PaneRectSolver` + `GridCompositor`).
        "pane-border-status": .string("off"),
        "pane-border-format": .string(" #{pane_index} #{pane_title} "),
        // Lifecycle/timing. `remain-on-exit` on (Harness's safe default; tmux defaults off)
        // keeps a pane's dead leaf so `respawn-pane` can revive it; off closes the pane (or
        // its tab when last) when the shell exits — read in the daemon's PTY-exit handler.
        "remain-on-exit": .bool(true),
        // Per-surface secrets-at-rest control: when off, the surface's scrollback is never
        // written to disk (and anything already written is removed). Pane-scoped reads fall
        // back to global, so `set-option persist-scrollback off` covers everything.
        "persist-scrollback": .bool(true),
        // Auto-injected OSC 133 shell integration at spawn (zsh/bash/fish). Off = panes
        // spawn untouched; the manual `install-shell-integration` path still works.
        "shell-integration": .bool(true),
        // `repeat-time` (ms): how long the prefix stays armed after a repeatable binding
        // (`bind -r`) so the key repeats without re-pressing the prefix. Read by `PrefixKeymap`.
        "repeat-time": .int(500),
        // How Harness identifies itself to programs (`TERM_PROGRAM` env + XTVERSION/secondary-DA
        // replies). `compatible` (default) reports a protocol-compatible identity so tools like
        // Claude Code enable Kitty-keyboard / Shift+Enter immediately; `harness` reports the true
        // name. Read by the daemon (env, via `TerminalIdentity`) and the app (XTVERSION reply).
        TerminalIdentity.optionKey: .string(TerminalIdentity.Mode.compatible.rawValue),
        // How long display-message / status flashes stay visible (ms). Read by the GUI
        // message overlay and the attach-window compositor.
        "display-time": .int(750),
        // When on, attach clients set the OUTER terminal's title (OSC 2) to the rendered
        // `set-titles-string`. The GUI keeps its native window title handling.
        "set-titles": .bool(false),
        "set-titles-string": .string("#{session_name}:#{window_name} — Harness"),
        // When the attached session is destroyed: `on` (default, tmux) detaches the
        // attach-window client; `off` re-targets the most recently active surviving session.
        "detach-on-destroy": .bool(true),
    ]

    /// Values that shipped as defaults in an earlier build and have since been
    /// fixed. Saved copies that match these exactly get upgraded to the current
    /// `builtinDefaults` on load — user-edited values don't match and survive.
    private static let supersededDefaults: [String: [Value]] = [
        "status-left": [
            .string(" #{workspace_name} · #{session_name} "),
        ],
        "status-right": [
            .string(" #{cwd_basename}#{?git_branch, · #{git_branch},} · %H:%M "),
        ],
    ]

    /// Returns true if any value was migrated (caller should re-save).
    static func migrateSupersededDefaults(_ values: inout [String: Value]) -> Bool {
        var changed = false
        for (key, oldValues) in supersededDefaults {
            guard let current = builtinDefaults[key] else { continue }
            let id = encodeKey(ScopedKey(scope: .global, key: key))
            guard let stored = values[id], oldValues.contains(stored) else { continue }
            values[id] = current
            changed = true
        }
        return changed
    }

    private static func fallbackOrder(from scope: Scope) -> [Scope] {
        switch scope {
        case .pane: return [.tab, .session, .workspace, .global]
        case .tab: return [.session, .workspace, .global]
        case .session: return [.workspace, .global]
        case .workspace: return [.global]
        case .global: return []
        }
    }

    private static func encodeKey(_ key: ScopedKey) -> String {
        if let target = key.target {
            return "\(key.scope.rawValue):\(target):\(key.key)"
        }
        return "\(key.scope.rawValue)::\(key.key)"
    }

    private static func decodeKey(_ id: String) -> ScopedKey? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let scope = Scope(rawValue: parts[0]) else { return nil }
        return ScopedKey(
            scope: scope,
            target: parts[1].isEmpty ? nil : parts[1],
            key: parts[2]
        )
    }

    // MARK: Persistence

    private func save() {
        // Snapshot under the lock — encoding `values` while another thread mutates it is a torn
        // read of the dictionary (the store is `@unchecked Sendable`; the daemon sets options and
        // serves `show-options` concurrently). The snapshot is captured HERE (on the caller's
        // thread, still under the conceptual mutation context) so the debounced write on `saveQueue`
        // sees a consistent picture of the state at the time of the last mutation in the burst.
        lock.lock()
        let snapshot = values
        lock.unlock()
        saveQueue.async { [weak self] in
            self?.scheduleSave(snapshot)
        }
    }

    /// Synchronously write the current values to disk, bypassing the debounce. Called on daemon
    /// shutdown (via `SurfaceRegistry.flushSnapshot`'s companion) so the last options write in the
    /// debounce window is never lost.
    public func flush() {
        // Cancel any pending debounced write, then persist synchronously on `saveQueue` — the
        // same serialisation point all debounced writes use, so we never race a concurrent write.
        saveQueue.sync { [weak self] in
            guard let self else { return }
            pendingSave?.cancel()
            pendingSave = nil
            lock.lock()
            let snapshot = values
            lock.unlock()
            writeToDisk(snapshot)
        }
    }

    private func scheduleSave(_ snapshot: [String: Value]) {
        // Cancel the previous pending write and replace it, so a burst of mutations coalesces
        // into one disk write — identical in shape to SessionStore.scheduleSave.
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk(snapshot) }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func writeToDisk(_ snapshot: [String: Value]) {
        try? HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        HarnessPaths.atomicWrite(data, to: url, label: "HarnessDaemon")
    }

    private static func load(url: URL) -> [String: Value] {
        guard let data = try? Data(contentsOf: url) else { return [:] } // absent → fresh install
        if let decoded = try? JSONDecoder().decode([String: Value].self, from: data) {
            return decoded
        }
        // Present but unparseable: preserve it as `.corrupt` for recovery rather than letting
        // the caller silently overwrite it with defaults (which would discard the user's options).
        HarnessPaths.backupCorruptFile(at: url, label: "HarnessDaemon")
        return [:]
    }
}

extension OptionStore.Value {
    public var boolValue: Bool {
        switch self {
        case let .bool(value): return value
        case let .int(value): return value != 0
        case let .string(value):
            return !["", "0", "false", "off", "no"].contains(value.lowercased())
        }
    }

    public var intValue: Int {
        switch self {
        case let .bool(value): return value ? 1 : 0
        case let .int(value): return value
        case let .string(value): return Int(value) ?? 0
        }
    }

    public var stringValue: String {
        switch self {
        case let .bool(value): return value ? "on" : "off"
        case let .int(value): return String(value)
        case let .string(value): return value
        }
    }

    /// Number of status lines a `status` value denotes (tmux allows `status 2..5`):
    /// `off`/`false`/`0` → 0 (hidden), `on`/`true` → 1, an integer N → N clamped to
    /// 0...5. The GUI status bar and the ssh compositor both read this so they reserve
    /// the **same** row count — never a hardcoded single line.
    public var statusLineCount: Int {
        switch self {
        case let .bool(value): return value ? 1 : 0
        case let .int(value): return max(0, min(5, value))
        case let .string(value):
            if let n = Int(value) { return max(0, min(5, n)) }
            return boolValue ? 1 : 0
        }
    }

    /// Coerce a raw textual representation (from `set-option -g status on`).
    public init(parsing raw: String) {
        if let int = Int(raw) { self = .int(int); return }
        let lowered = raw.lowercased()
        if ["true", "on", "yes"].contains(lowered) { self = .bool(true); return }
        if ["false", "off", "no"].contains(lowered) { self = .bool(false); return }
        self = .string(raw)
    }
}
