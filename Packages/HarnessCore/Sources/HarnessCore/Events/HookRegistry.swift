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
public final class HookRegistry: @unchecked Sendable {
    public typealias Executor = @Sendable (Command, FormatContext) -> Void

    private var hooks: [Hook] = []
    private let url: URL
    private let lock = NSLock()
    private var executor: Executor?

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
        try? HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(hooks) else { return }
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
