import Foundation

/// Catalog of events the daemon emits. Hooks bind to these so users can
/// script reactions ("when a new tab opens, display a message", "when a pane
/// exits, source a config", etc.).
public enum HookEvent: String, Codable, Sendable, CaseIterable {
    case afterNewTab = "after-new-tab"
    case afterNewSession = "after-new-session"
    case afterKillTab = "after-kill-tab"
    case afterSplitPane = "after-split-pane"
    case afterKillPane = "after-kill-pane"
    case afterResizePane = "after-resize-pane"
    case paneExited = "pane-exited"
    case clientAttached = "client-attached"
    case clientDetached = "client-detached"
    case agentStateChanged = "agent-state-changed"
    case notificationPosted = "notification-posted"
    // Monitoring (Phase 5): fired by the daemon when a watched pane produces output after
    // being idle (`alert-activity`), goes quiet for `monitor-silence` seconds
    // (`alert-silence`), or emits a bell (`alert-bell`). Gated on the matching option.
    case paneActivity = "alert-activity"
    case paneSilence = "alert-silence"
    case paneBell = "alert-bell"
    // tmux session/window lifecycle events. `session-created` fires alongside
    // `after-new-session` (tmux emits both); renames fire for manual AND
    // OSC/automatic renames, like tmux. `window-layout-changed` fires for the
    // layout verbs (apply/next/previous/rotate) — splits/kills/resizes already
    // have their own after-* events.
    case sessionCreated = "session-created"
    case sessionRenamed = "session-renamed"
    case sessionClosed = "session-closed"
    case windowRenamed = "window-renamed"
    case windowLinked = "window-linked"
    case windowUnlinked = "window-unlinked"
    case windowLayoutChanged = "window-layout-changed"
    // `command-error` fires when a command fails loudly (an `.error` from the command path).
    // `pane-focus-in`/`-out` fire when the active pane gains/loses focus; `window-pane-changed`
    // fires when a tab's active pane changes (select-pane / directional nav / split focus).
    case commandError = "command-error"
    case paneFocusIn = "pane-focus-in"
    case paneFocusOut = "pane-focus-out"
    case windowPaneChanged = "window-pane-changed"
}

/// One binding: event → command (with an optional `if` condition format).
public struct Hook: Codable, Sendable, Equatable {
    public var id: UUID
    public var event: HookEvent
    public var command: Command
    public var conditionFormat: String?
    public init(event: HookEvent, command: Command, conditionFormat: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.event = event
        self.command = command
        self.conditionFormat = conditionFormat
    }
}

/// Holds bound hooks and fires them when the daemon emits events. Reads/writes
/// `hooks.json` so user-defined hooks survive restart.
///
/// @unchecked Sendable: mutable state is protected by `lock`; disk writes and the debounce
/// timer are confined to `saveQueue` — the same two-layer pattern as `SessionStore`.
public final class HookRegistry: @unchecked Sendable {
    public typealias Executor = @Sendable (Command, FormatContext) -> Void

    private var hooks: [Hook] = []
    private let url: URL
    private let lock = NSLock()
    private var executor: Executor?
    // Debounced write — mirrors SessionStore/OptionStore. A user binding/unbinding hooks rapidly
    // (e.g. sourcing a config file) produces one disk write at the end of the burst.
    private let saveQueue = DispatchQueue(label: "com.robert.harness.hook-registry-save")
    private var pendingSave: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.15

    public init(url: URL? = nil) {
        self.url = url ?? HarnessPaths.applicationSupport.appendingPathComponent("hooks.json")
        self.hooks = Self.load(url: self.url)
    }

    public func setExecutor(_ executor: @escaping Executor) {
        lock.lock(); defer { lock.unlock() }
        self.executor = executor
    }

    public func bind(event: HookEvent, command: Command, conditionFormat: String? = nil) -> UUID {
        lock.lock()
        let hook = Hook(event: event, command: command, conditionFormat: conditionFormat)
        hooks.append(hook)
        lock.unlock()
        save()
        return hook.id
    }

    @discardableResult
    public func unbind(id: UUID) -> Bool {
        lock.lock()
        let before = hooks.count
        hooks.removeAll { $0.id == id }
        let removed = hooks.count != before
        lock.unlock()
        if removed { save() }
        return removed
    }

    public func list(event: HookEvent? = nil) -> [Hook] {
        lock.lock(); defer { lock.unlock() }
        if let event { return hooks.filter { $0.event == event } }
        return hooks
    }

    /// Fire every hook bound to `event`. The condition format (if present)
    /// must evaluate to a truthy string for the command to run.
    public func fire(_ event: HookEvent, context: FormatContext) {
        lock.lock()
        let matching = hooks.filter { $0.event == event }
        let exec = executor
        lock.unlock()
        guard let exec else { return }
        for hook in matching {
            if let format = hook.conditionFormat {
                let evaluated = FormatString.evaluate(format, context: context)
                if evaluated.isEmpty || evaluated == "0" || evaluated.lowercased() == "false" { continue }
            }
            exec(hook.command, context)
        }
    }

    private func save() {
        // Snapshot under the lock — encoding `hooks` while another thread mutates it (bind/unbind
        // release the lock before save()) is a torn read of the array (mirrors OptionStore /
        // EnvironmentStore). The snapshot is captured here so the debounced write on `saveQueue`
        // reflects the state at the time of the last mutation in the burst.
        lock.lock()
        let snapshot = hooks
        lock.unlock()
        saveQueue.async { [weak self] in
            self?.scheduleSave(snapshot)
        }
    }

    /// Synchronously write the current hooks to disk, bypassing the debounce. Called on daemon
    /// shutdown so the last hook change in the debounce window is never lost.
    public func flush() {
        saveQueue.sync { [weak self] in
            guard let self else { return }
            pendingSave?.cancel()
            pendingSave = nil
            lock.lock()
            let snapshot = hooks
            lock.unlock()
            writeToDisk(snapshot)
        }
    }

    private func scheduleSave(_ snapshot: [Hook]) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk(snapshot) }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func writeToDisk(_ snapshot: [Hook]) {
        try? HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        HarnessPaths.atomicWrite(data, to: url, label: "HarnessDaemon")
    }

    private static func load(url: URL) -> [Hook] {
        // Absent file is the normal case (no hooks bound yet) — start empty silently.
        guard let data = try? Data(contentsOf: url) else { return [] }
        if let hooks = try? JSONDecoder().decode([Hook].self, from: data) { return hooks }
        // Present but unparseable: preserve it as `.corrupt` for recovery rather than
        // silently discarding the user's bindings (mirrors OptionStore / SessionStore).
        HarnessPaths.backupCorruptFile(at: url, label: "HarnessDaemon")
        return []
    }
}
