import Foundation

/// A tmux-style `-t session:window.pane` target reference, parsed from a command
/// flag and resolved against a `SessionSnapshot` at translate time.
///
/// Any component may be omitted. At resolution an omitted *higher* level falls
/// back to the focused/active chain (the calling client's focus), and an omitted
/// *lower* level falls back to that target's active window / pane — exactly tmux's
/// behavior. A lone token with no `:` / `.` separators (e.g. `2`, `+`, `!`) is
/// level-ambiguous; it is assigned to the addressed command's natural level
/// (window vs pane) at resolution, matching tmux's context-sensitive `-t`.
///
/// Grammar (tmux muscle memory):
///   session : `name` | `$`uuid | `+`(next) | `-`(previous)
///   window  : index | `name` | `@`uuid | `!`(last/MRU) | `+`(next) | `-`(prev)
///             | `^`/`{start}`(first) | `$`/`{end}`(highest index) | `{last}`
///   pane    : index | `%`uuid | `!`/`{last}` | `+`/`{next}` | `-`/`{previous}`
///             | `{top}` | `{bottom}` | `{left}` | `{right}`
public struct TargetSpec: Codable, Sendable, Equatable {
    public enum SessionRef: Codable, Sendable, Equatable {
        case byName(String)
        case byID(UUID)
        case next
        case previous
    }

    public enum WindowRef: Codable, Sendable, Equatable {
        case byIndex(Int)
        case byName(String)
        case byID(UUID)
        case last        // ! — most-recently-active (MRU)
        case next        // +
        case previous    // -
        case first       // ^ / {start}
        case highest     // $ / {end} — greatest index in the list
    }

    public enum PaneRef: Codable, Sendable, Equatable {
        case byIndex(Int)
        case byID(UUID)
        case last        // ! / {last} — most-recently-active
        case next        // + / {next}
        case previous    // - / {previous}
        case top, bottom, left, right
    }

    public var session: SessionRef?
    public var window: WindowRef?
    public var pane: PaneRef?
    /// A lone token with no `:` / `.` separators that is level-ambiguous (a plain
    /// index or a relative `!`/`+`/`-`); resolved as a window or pane ref per the
    /// addressed command's level. Unambiguous lone tokens (`$id`, `@id`, `%id`, a
    /// name) are classified into `session`/`window`/`pane` directly at parse time.
    public var bareToken: String?
    public var raw: String

    public init(
        session: SessionRef? = nil,
        window: WindowRef? = nil,
        pane: PaneRef? = nil,
        bareToken: String? = nil,
        raw: String = ""
    ) {
        self.session = session
        self.window = window
        self.pane = pane
        self.bareToken = bareToken
        self.raw = raw
    }

    public var isEmpty: Bool {
        session == nil && window == nil && pane == nil && bareToken == nil
    }

    // MARK: Parsing

    /// Parse a raw `-t` target string. Tolerant: an unrecognized component
    /// becomes `nil` (falls back to the active chain) rather than throwing, so a
    /// typo degrades to "act on the focused target" instead of erroring.
    public static func parse(_ raw: String) -> TargetSpec {
        var spec = TargetSpec(raw: raw)
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return spec }

        // Split session via the first ':'. Session names cannot contain ':' or '.'.
        var sessionToken: String?
        var rest = Substring(trimmed)
        if let colon = trimmed.firstIndex(of: ":") {
            sessionToken = String(trimmed[trimmed.startIndex..<colon])
            rest = trimmed[trimmed.index(after: colon)...]
        }

        // No separators at all → a single level-ambiguous-or-typed token.
        if sessionToken == nil, !rest.contains(".") {
            classifyLone(String(rest), into: &spec)
            return spec
        }

        // Split the remainder into window[.pane].
        var windowToken: String?
        var paneToken: String?
        if let dot = rest.firstIndex(of: ".") {
            windowToken = String(rest[rest.startIndex..<dot])
            paneToken = String(rest[rest.index(after: dot)...])
        } else {
            windowToken = String(rest)
        }

        spec.session = sessionToken.flatMap(parseSessionToken)
        if let windowToken, !windowToken.isEmpty { spec.window = parseWindowToken(windowToken) }
        if let paneToken, !paneToken.isEmpty { spec.pane = parsePaneToken(paneToken) }
        return spec
    }

    /// Classify a lone token (no `:`/`.`). Unambiguous forms land in a typed slot;
    /// a plain index or relative marker is held as `bareToken` for level-dependent
    /// resolution.
    private static func classifyLone(_ token: String, into spec: inout TargetSpec) {
        if token.isEmpty { return }
        if token.hasPrefix("$") { spec.session = parseSessionToken(token); return }
        if token.hasPrefix("@") { spec.window = parseWindowToken(token); return }
        if token.hasPrefix("%") { spec.pane = parsePaneToken(token); return }
        // Plain index or relative marker → ambiguous (window vs pane).
        if Int(token) != nil || ["!", "+", "-", "^"].contains(token) {
            spec.bareToken = token
            return
        }
        if token.hasPrefix("{") { spec.bareToken = token; return }
        // A bare name → session (tmux: bare name targets a session).
        spec.session = .byName(token)
    }

    static func parseSessionToken(_ token: String) -> SessionRef? {
        if token.hasPrefix("$"), let id = UUID(uuidString: String(token.dropFirst())) { return .byID(id) }
        switch token {
        case "", ".": return nil          // current/active session
        case "+": return .next
        case "-": return .previous
        default: return .byName(token)
        }
    }

    static func parseWindowToken(_ token: String) -> WindowRef? {
        if token.hasPrefix("@"), let id = UUID(uuidString: String(token.dropFirst())) { return .byID(id) }
        switch token {
        case "": return nil               // current/active window
        case "!", "{last}": return .last
        case "+", "{next}": return .next
        case "-", "{previous}": return .previous
        case "^", "{start}": return .first
        case "$", "{end}": return .highest
        default:
            if let n = Int(token) { return .byIndex(n) }
            return .byName(token)
        }
    }

    static func parsePaneToken(_ token: String) -> PaneRef? {
        if token.hasPrefix("%"), let id = UUID(uuidString: String(token.dropFirst())) { return .byID(id) }
        switch token {
        case "": return nil               // current/active pane
        case "!", "{last}": return .last
        case "+", "{next}": return .next
        case "-", "{previous}": return .previous
        case "{top}": return .top
        case "{bottom}": return .bottom
        case "{left}": return .left
        case "{right}": return .right
        default:
            if let n = Int(token) { return .byIndex(n) }
            return nil
        }
    }
}

// MARK: - Command target level

extension Command {
    /// The finest hierarchy level a command addresses. Used to resolve a
    /// level-ambiguous lone `-t` token (a plain index or relative marker) into a
    /// window vs pane reference, matching tmux's context-sensitive targets.
    public enum TargetKind: Sendable, Equatable { case session, window, pane }

    public var targetKind: TargetKind {
        switch self {
        case .splitWindow, .killPane, .zoomPane, .selectPane, .swapPane, .resizePane,
             .markPane, .joinPane, .movePane, .breakPane, .respawnPane, .sendKeys, .pipePane,
             .copyMode, .displayPanes, .synchronizePanes:
            return .pane
        case .newWindow, .killWindow, .renameWindow, .nextWindow, .previousWindow,
             .selectWindow, .moveWindow, .swapWindow, .renumberWindows, .rotateWindow,
             .selectLayout, .nextLayout, .previousLayout, .lastWindow, .linkWindow, .unlinkWindow:
            return .window
        case .newSession, .killSession, .renameSession:
            return .session
        default:
            return .window
        }
    }
}

// MARK: - Resolution

extension CommandTarget {
    /// Resolve a `TargetSpec` against this target's snapshot, returning a copy with
    /// the focused workspace/tab/pane overridden by the spec. Components the spec
    /// omits keep the receiver's focus (the active chain). `baseIndex` /
    /// `paneBaseIndex` offset 1-based (or user-configured) window/pane indices to
    /// array positions.
    public func resolving(
        _ spec: TargetSpec,
        command: Command? = nil,
        baseIndex: Int = 0,
        paneBaseIndex: Int = 0
    ) -> CommandTarget {
        if spec.isEmpty { return self }
        var result = self
        let kind = command?.targetKind ?? .window

        // 1. Session → workspace + session (and default the tab to its active tab).
        if let sref = spec.session, let (ws, sg) = Self.findSession(sref, in: snapshot, current: session) {
            result.focusedWorkspaceID = ws.id
            result.focusedTabID = sg.activeTab?.id
            result.focusedPaneID = nil
        }

        // 2. Window (explicit, or a bare token when the command addresses a window).
        let windowRef = spec.window ?? (kind == .window ? spec.bareToken.flatMap(TargetSpec.parseWindowToken) : nil)
        if let wref = windowRef, let sg = result.session,
           let tab = Self.findWindow(wref, in: sg, baseIndex: baseIndex) {
            result.focusedTabID = tab.id
            result.focusedPaneID = nil
        }

        // 3. Pane (explicit, or a bare token when the command addresses a pane).
        let paneRef = spec.pane ?? (kind == .pane ? spec.bareToken.flatMap(TargetSpec.parsePaneToken) : nil)
        if let pref = paneRef, let tab = result.tab,
           let pid = Self.findPane(pref, in: tab, baseIndex: paneBaseIndex) {
            result.focusedPaneID = pid
        }
        return result
    }

    // MARK: Session / window / pane lookup

    /// All `(workspace, session)` pairs ordered by `(workspace.sortOrder,
    /// session.sortOrder)` — the stable order for relative session stepping.
    static func orderedSessions(in snapshot: SessionSnapshot) -> [(Workspace, SessionGroup)] {
        snapshot.workspaces
            .sorted { $0.sortOrder < $1.sortOrder }
            .flatMap { ws in ws.sessions.sorted { $0.sortOrder < $1.sortOrder }.map { (ws, $0) } }
    }

    static func findSession(
        _ ref: TargetSpec.SessionRef,
        in snapshot: SessionSnapshot,
        current: SessionGroup?
    ) -> (Workspace, SessionGroup)? {
        let all = orderedSessions(in: snapshot)
        switch ref {
        case let .byID(id):
            return all.first { $0.1.id == id }
        case let .byName(name):
            return all.first { $0.1.name == name } ?? all.first { $0.1.id.uuidString == name }
        case .next, .previous:
            guard !all.isEmpty else { return nil }
            let delta = ref == .next ? 1 : -1
            let idx = current.flatMap { c in all.firstIndex { $0.1.id == c.id } } ?? 0
            let next = ((idx + delta) % all.count + all.count) % all.count
            return all[next]
        }
    }

    static func findWindow(
        _ ref: TargetSpec.WindowRef,
        in session: SessionGroup,
        baseIndex: Int = 0
    ) -> Tab? {
        let tabs = session.tabs.sorted { $0.sortOrder < $1.sortOrder }
        guard !tabs.isEmpty else { return nil }
        switch ref {
        case let .byIndex(n):
            let pos = n - baseIndex
            return tabs.indices.contains(pos) ? tabs[pos] : nil
        case let .byName(name):
            return tabs.first { $0.title == name }
        case let .byID(id):
            return tabs.first { $0.id == id }
        case .last:
            return session.lastActiveTabID.flatMap { id in tabs.first { $0.id == id } } ?? session.activeTab
        case .first:
            return tabs.first
        case .highest:
            return tabs.last
        case .next, .previous:
            let delta = ref == .next ? 1 : -1
            let activeID = session.activeTabID ?? tabs.first?.id
            let idx = activeID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0
            let next = ((idx + delta) % tabs.count + tabs.count) % tabs.count
            return tabs[next]
        }
    }

    static func findPane(
        _ ref: TargetSpec.PaneRef,
        in tab: Tab,
        baseIndex: Int = 0
    ) -> PaneID? {
        let order = tab.rootPane.allPaneIDs()
        guard !order.isEmpty else { return nil }
        switch ref {
        case let .byIndex(n):
            let pos = n - baseIndex
            return order.indices.contains(pos) ? order[pos] : nil
        case let .byID(id):
            return order.contains(id) ? id : nil
        case .last:
            return tab.lastActivePaneID ?? tab.activePaneID
        case .next, .previous:
            let delta = ref == .next ? 1 : -1
            let current = tab.activePaneID ?? order.first
            let idx = current.flatMap { order.firstIndex(of: $0) } ?? 0
            let next = ((idx + delta) % order.count + order.count) % order.count
            return order[next]
        case .top, .bottom, .left, .right:
            // Geometry is ratio-based, so any fixed cell area gives the correct
            // extreme pane. Reuse the compositor's solver rather than re-deriving.
            let rects = PaneRectSolver.solve(tab.rootPane, cols: 1000, rows: 1000, border: false)
            guard !rects.isEmpty else { return order.first }
            switch ref {
            case .top: return rects.min { $0.y < $1.y }?.paneID
            case .bottom: return rects.max { ($0.y + $0.rows) < ($1.y + $1.rows) }?.paneID
            case .left: return rects.min { $0.x < $1.x }?.paneID
            case .right: return rects.max { ($0.x + $0.cols) < ($1.x + $1.cols) }?.paneID
            default: return order.first
            }
        }
    }
}
