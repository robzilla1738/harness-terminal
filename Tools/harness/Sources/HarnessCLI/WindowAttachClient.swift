import Darwin
import Foundation
import HarnessCopyMode
import HarnessCore
import HarnessTerminalEngine
import HarnessTerminalKit

/// Renders a daemon-owned **window** (a tab's full split layout) into a plain
/// terminal — the headline `harness attach` compositor. Unlike `AttachClient`
/// (single-pane passthrough), this lays out every pane with borders, emulates
/// each pane's screen locally with a renderer-free `HarnessGridTerminal`, and paints
/// a composited frame via `GridCompositor`.
///
/// Architecture (client-side emulation, the same shape the GUI uses): the
/// daemon stays a dumb PTY byte pipe. Per pane we `subscribeSurfaceOutput` +
/// `replayScrollback`, feed the bytes into a `HarnessGridTerminal`, read its styled
/// grid, and composite. Input is forwarded to the active pane; the prefix key
/// drives local pane navigation and detach. SIGWINCH re-lays-out; a snapshot
/// poll rebuilds when the split structure changes.
public enum WindowAttachClient {
    public enum TabSelector {
        case active
        case id(String)        // --tab / --window
        case session(String)   // --session: that session's active tab
    }

    public struct Configuration {
        public var detachSequence: [UInt8] = [0x01, 0x64] // Ctrl-A d
        public var prefix: UInt8 = 0x01                   // Ctrl-A
        public var label: String = "harness-cli attach-window"
        public init() {}
    }

    public static func run(tab selector: TabSelector, configuration: Configuration = Configuration()) throws -> Int32 {
        guard isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
            fputs("harness-cli attach-window: stdin/stdout must be a TTY\n", stderr)
            return 64
        }
        if ProcessInfo.processInfo.environment["HARNESS"] != nil {
            // The `$TMUX` analog: this is running inside a Harness pane. Allowed
            // (handy for testing), but warn so accidental nesting is visible.
            fputs("harness-cli attach-window: already inside Harness ($HARNESS set); nesting — detach with the prefix.\n", stderr)
        }
        let client = DaemonClient()
        guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
            fputs("harness-cli attach-window: could not read session snapshot\n", stderr)
            return 1
        }
        guard let tab = resolveTab(snapshot, selector: selector) else {
            fputs("harness-cli attach-window: no matching tab\n", stderr)
            return 1
        }
        guard let location = locate(tabID: tab.id, in: snapshot) else {
            fputs("harness-cli attach-window: tab is not in any session\n", stderr)
            return 1
        }
        // Make the requested tab the session's active window, then follow the
        // session: like a multiplexer client, this view tracks whichever window
        // the session has focused (GUI tab switches move it too).
        _ = try? client.request(.selectTab(workspaceID: location.workspaceID, tabID: tab.id), timeout: 1)

        let original = AttachClient.enterRawMode()
        defer { AttachClient.restoreTerminalMode(original) }

        let session = WindowSession(
            client: client,
            tab: tab,
            workspaceID: location.workspaceID,
            sessionID: location.sessionID,
            configuration: configuration
        )
        do {
            try session.run()
        } catch {
            AttachClient.restoreTerminalMode(original)
            fputs("\nharness-cli attach-window: \(error)\n", stderr)
            return 1
        }
        return 0
    }

    static func resolveTab(_ snapshot: SessionSnapshot, selector: TabSelector) -> Tab? {
        switch selector {
        case .active:
            let ws = snapshot.workspaces.first { $0.id == snapshot.activeWorkspaceID } ?? snapshot.workspaces.first
            guard let ws else { return nil }
            let sess = ws.sessions.first { $0.id == ws.activeSessionID } ?? ws.sessions.first
            guard let sess else { return nil }
            return sess.tabs.first { $0.id == sess.activeTabID } ?? sess.tabs.first
        case let .id(raw):
            let needle = raw.lowercased()
            for ws in snapshot.workspaces {
                for sess in ws.sessions {
                    if let t = sess.tabs.first(where: { $0.id.uuidString.lowercased() == needle }) {
                        return t
                    }
                }
            }
            return nil
        case let .session(raw):
            let needle = raw.lowercased()
            for ws in snapshot.workspaces {
                for sess in ws.sessions where sess.id.uuidString.lowercased() == needle || sess.name.lowercased() == needle {
                    return sess.tabs.first { $0.id == sess.activeTabID } ?? sess.tabs.first
                }
            }
            return nil
        }
    }

    static func locate(tabID: TabID, in snapshot: SessionSnapshot) -> (workspaceID: WorkspaceID, sessionID: SessionID)? {
        for ws in snapshot.workspaces {
            for sess in ws.sessions where sess.tabs.contains(where: { $0.id == tabID }) {
                return (ws.id, sess.id)
            }
        }
        return nil
    }
}

// MARK: - Window session

private final class WindowSession: @unchecked Sendable {
    private let client: DaemonClient
    private let configuration: WindowAttachClient.Configuration
    private var tab: Tab
    private let workspaceID: WorkspaceID?
    private let sessionID: SessionID
    /// Merged prefix/copy-mode key tables (defaults + `keybindings.json`), so the
    /// compositor honors the exact same bindings — and user overrides — as the GUI.
    private let keyTables: KeyTableSet
    /// Marked pane (join-pane source); client-tracked like `select-pane -m`.
    private var markedPaneID: PaneID?
    /// Latest snapshot, refreshed on every structure check — the translator
    /// resolves targets against it.
    private var latestSnapshot: SessionSnapshot?
    /// Resolved status options (`status`, `status-left`, `status-right`),
    /// refreshed from the daemon so the status line matches the GUI's.
    private var statusOptions: [String: String] = [:]
    /// `base-index` / `pane-base-index`, refreshed with the status options so
    /// `-t session:window.pane` indices match the user's configured base.
    private var baseIndex = 0
    private var paneBaseIndex = 0
    /// `window-style`/`pane-style` base colors (dim inactive panes), refreshed with the
    /// status options. The active pane uses the `*-active-style` base; others the general one.
    private var paneStyles = PaneStyleSet()
    /// `pane-border-status` (off/top/bottom) + `pane-border-format`, refreshed with the
    /// status options; the solver reserves a label row and the compositor draws the label.
    private var paneBorderStatus: PaneBorderStatus = .off
    private var paneBorderFormat = ""
    /// A transient status override (e.g. `display-message`), shown briefly.
    private var statusOverride: String?
    private var statusOverrideToken = 0
    /// Current composited dimensions (kept for status-line right-alignment).
    private var cols = 80
    private var rows = 24

    /// All pane work — feeding HarnessGridTerminals, compositing, writing stdout —
    /// runs on this serial queue. HarnessGridTerminal is not thread-safe, so every
    /// access is funneled here.
    private let renderQueue = DispatchQueue(label: "harness.window.render")
    private var terminals: [String: HarnessGridTerminal] = [:]
    private var subscriptions: [DaemonSubscription] = []
    private var rects: [PaneRect] = []
    private var compositor: GridCompositor
    private var activeSurface: String?
    private var renderScheduled = false
    /// DEC 2026 synchronized-output safety valve (force a present if a pane never ends a frame).
    private var syncTimeout: DispatchWorkItem?
    /// Status-band rows reserved by the last `rebuildLayout` (so a copy-mode/flash toggle that
    /// changes the band can re-solve the pane rects instead of overpainting them).
    private var reservedStatus = 1
    /// Set on renderQueue during teardown so any already-deferred render (scheduleRender /
    /// flashStatus / display-panes asyncAfter) bails instead of writing stdout after the final
    /// cleanup sequence — no interleaved/garbled output on detach.
    private var tornDown = false

    // MARK: Copy mode / mouse / synchronize (Phase 3)
    /// Copy mode over the focused pane — the same shared `CopyModeReducer` the GUI drives.
    private var copyMode: CopyModeState?
    private var copyModeSurface: String?
    private var copyModeSearchEntry: String?
    /// `synchronize-panes`: mirror forwarded input to every pane in the window.
    private var synchronize = false
    /// `display-panes`: overlay pane numbers until the next key / timeout.
    private var showPaneNumbers = false
    private var displayPanesToken = 0
    /// Options the input/clipboard paths read (refreshed with the status options).
    private var modeKeys = "vi"
    private var mouseEnabled = false
    private var allowClipboard = true

    private let detachLock = NSLock()
    private var detachRequested = false
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var sigwinch: DispatchSourceSignal?
    private var sigterm: DispatchSourceSignal?
    private var snapshotSubscription: DaemonSubscription?

    init(client: DaemonClient, tab: Tab, workspaceID: WorkspaceID?, sessionID: SessionID, configuration: WindowAttachClient.Configuration) {
        self.client = client
        self.tab = tab
        self.workspaceID = workspaceID
        self.sessionID = sessionID
        self.configuration = configuration
        self.keyTables = KeybindingsStore.load()
        let size = AttachClient.ttySize()
        self.compositor = GridCompositor(cols: Int(size?.cols ?? 80), rows: Int(size?.rows ?? 24))
    }

    func run() throws {
        try installWakePipe()
        installSignalHandlers()
        renderQueue.sync {
            if case let .snapshot(snapshot)? = try? client.request(.getSnapshot, timeout: 1) {
                latestSnapshot = snapshot
            }
            refreshStatusOptions()
            rebuildLayout(initial: true)
        }
        installSnapshotSubscription()
        runInputLoop()
        teardown()
    }

    // MARK: Layout

    /// (Re)compute pane rects and (re)create the per-pane terminals + output
    /// subscriptions for the current tab + TTY size. Must run on `renderQueue`.
    private func rebuildLayout(initial: Bool) {
        let size = AttachClient.ttySize()
        let cols = Int(size?.cols ?? 80)
        let rows = Int(size?.rows ?? 24)
        self.cols = cols
        self.rows = rows
        compositor.resize(cols: cols, rows: rows)

        reservedStatus = reservedStatusRows()
        let contentRows = max(1, rows - reservedStatus) // reserve the status band (status 1..5)

        // Compute rects. A zoomed pane takes the whole content area.
        if let zoomed = tab.zoomedPaneID, let leaf = findLeaf(tab.rootPane, paneID: zoomed) {
            rects = [PaneRect(paneID: leaf.id, surfaceID: leaf.surfaceID, x: 0, y: 0, cols: cols, rows: contentRows)]
        } else {
            rects = PaneRectSolver.solve(tab.rootPane, cols: cols, rows: contentRows, paneBorderStatus: paneBorderStatus)
        }

        let wanted = Set(rects.map { $0.surfaceID.uuidString })

        // Drop terminals/subscriptions for panes that no longer exist.
        for (sid, _) in terminals where !wanted.contains(sid) {
            terminals[sid] = nil
        }
        subscriptions = subscriptions.filter { _ in true } // (kept; cancel on teardown)

        // Create terminals + subscriptions for new panes; resize existing ones.
        for rect in rects {
            let sid = rect.surfaceID.uuidString
            if let term = terminals[sid] {
                term.resize(cols: rect.cols, rows: rect.rows)
            } else {
                guard let term = HarnessGridTerminal(cols: rect.cols, rows: rect.rows) else { continue }
                terminals[sid] = term
                // OSC 52 from a pane → set the client's own clipboard (gated on set-clipboard)
                // and mirror into the daemon buffer so other clients see it.
                term.onSetClipboard = { [weak self] text in self?.handleProgramClipboard(text, surface: sid) }
                // Tell the daemon this pane's PTY size, seed with scrollback,
                // then stream live output into the terminal.
                _ = try? client.request(.resizeSurface(surfaceID: sid, rows: UInt16(rect.rows), cols: UInt16(rect.cols)), timeout: 1)
                if case let .text(text)? = try? client.request(.replayScrollback(surfaceID: sid, fromSequence: nil), timeout: 5),
                   !text.isEmpty {
                    term.feed(text)
                }
                if let sub = try? client.subscribeSurfaceOutput(surfaceID: sid, label: configuration.label, onData: { [weak self] data, _ in
                    self?.ingest(surface: sid, data: data)
                }, onEnd: { [weak self] in
                    self?.scheduleStructureCheck()
                }) {
                    subscriptions.append(sub)
                }
            }
        }

        // Focus follows the daemon's authoritative active pane so the compositor agrees
        // with the GUI and other clients; fall back to the first rect.
        let serverActive = tab.activePaneID.flatMap { pid in
            rects.first(where: { $0.paneID == pid })?.surfaceID.uuidString
        }
        if let serverActive {
            activeSurface = serverActive
        } else if activeSurface == nil || !wanted.contains(activeSurface!) {
            activeSurface = rects.first?.surfaceID.uuidString
        }
        compositor.invalidate()
        composeAndWrite()
    }

    private func findLeaf(_ node: PaneNode, paneID: PaneID) -> PaneLeaf? {
        switch node {
        case let .leaf(leaf): return leaf.id == paneID ? leaf : nil
        case let .branch(_, _, first, second):
            return findLeaf(first, paneID: paneID) ?? findLeaf(second, paneID: paneID)
        }
    }

    // MARK: Rendering

    private func ingest(surface: String, data: Data) {
        renderQueue.async { [weak self] in
            guard let self, let term = self.terminals[surface] else { return }
            term.feed(data)
            // DEC 2026 synchronized output: hold the repaint while this pane is mid-frame, then
            // present atomically when it ends; a timeout guards a program that never closes it.
            if term.modes.synchronizedOutput {
                self.armSyncTimeout()
            } else {
                self.syncTimeout?.cancel(); self.syncTimeout = nil
                self.scheduleRender()
            }
        }
    }

    private func armSyncTimeout() {
        guard syncTimeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.syncTimeout = nil
            self?.scheduleRender()
        }
        syncTimeout = work
        renderQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Coalesce renders to ~120fps so a burst of output is one repaint.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        renderQueue.asyncAfter(deadline: .now() + 0.008) { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.composeAndWrite()
        }
    }

    private func composeAndWrite() {
        guard !tornDown else { return } // detaching — don't paint over the cleanup sequence
        var panes: [CompositorPane] = []
        panes.reserveCapacity(rects.count)
        // Resolve the active/inactive base styles once; map each to engine colors.
        let activeBase = paneStyles.base(active: true)
        let inactiveBase = paneStyles.base(active: false)
        func base(_ active: Bool) -> (fg: TerminalGridColor, bg: TerminalGridColor) {
            let s = active ? activeBase : inactiveBase
            return (GridCompositor.gridColor(s.fg), GridCompositor.gridColor(s.bg))
        }
        // `pane-border-format` evaluated per pane (only when a label row was reserved).
        func borderLabel(_ rect: PaneRect, active: Bool) -> String? {
            guard rect.labelRow != nil, !paneBorderFormat.isEmpty else { return nil }
            return FormatString.evaluate(paneBorderFormat, context: paneFormatContext(rect: rect, active: active))
        }
        for rect in rects {
            let sid = rect.surfaceID.uuidString
            guard let term = terminals[sid] else { continue }
            if let cm = copyMode, sid == copyModeSurface {
                // The copy-mode pane renders at the model's scroll offset with selection /
                // search highlights and the copy-mode cursor (the shared projection).
                let offset = cm.scrollbackOffset(historyCount: term.historyCount)
                guard let grid = term.readGrid(scrollbackOffset: offset) else { continue }
                let b = base(true)
                panes.append(CompositorPane(
                    rect: rect, grid: grid, isActive: true,
                    selection: cm.viewportSelection(rows: rect.rows, columns: rect.cols),
                    searchHits: cm.viewportSearchHits(rows: rect.rows),
                    copyModeCursor: cm.viewportCursor(rows: rect.rows),
                    baseForeground: b.fg, baseBackground: b.bg,
                    borderLabel: borderLabel(rect, active: true)
                ))
            } else {
                guard let grid = term.readGrid() else { continue }
                let active = sid == activeSurface
                let b = base(active)
                panes.append(CompositorPane(
                    rect: rect, grid: grid, isActive: active,
                    baseForeground: b.fg, baseBackground: b.bg,
                    borderLabel: borderLabel(rect, active: active)
                ))
            }
        }
        var ansi = compositor.render(panes: panes, statusLines: statusLineSet())
        if showPaneNumbers { ansi += paneNumbersOverlay() }
        writeOut(ansi)
    }

    /// All status rows, **bottom-to-top** for `GridCompositor` (tmux `status 2..5`). The
    /// bottom (main) line is the `status-left`/`status-right` composition; a
    /// `display-message` override and copy-mode status replace it while active. Extra rows
    /// (`status-format-1…`) sit above it. Returns nil to hide the band when `status off`
    /// (unless an override/copy-mode line still needs the row).
    /// The number of bottom rows the status band occupies, matching exactly what
    /// `statusLineSet()` paints: the `status` option count (0..5), or 1 when a copy-mode /
    /// flash override is showing over an otherwise-hidden status bar. `PaneRectSolver` reserves
    /// this many rows so panes/borders never overlap the status band.
    private func reservedStatusRows() -> Int {
        let count = OptionStore.Value(parsing: statusOptions["status"] ?? "on").statusLineCount
        if count > 0 { return count }
        return (copyMode != nil || statusOverride != nil) ? 1 : 0
    }

    private func statusLineSet() -> [[StyledSegment]]? {
        let count = OptionStore.Value(parsing: statusOptions["status"] ?? "on").statusLineCount
        let override: [StyledSegment]?
        if let statusOverride { override = [StyledSegment(text: clip(statusOverride, to: cols))] }
        else if let cm = copyModeStatusLine() { override = [StyledSegment(text: cm)] }
        else { override = nil }
        guard count > 0 else { return override.map { [$0] } }
        let ctx = formatContext(target: currentTarget())
        var lines: [[StyledSegment]] = [override ?? mainStatusLine(ctx: ctx)]
        for i in 1 ..< count {
            lines.append(extraStatusLine(statusOptions["status-format-\(i)"] ?? "", ctx: ctx))
        }
        return lines
    }

    /// The bottom status line: `status-left` left-aligned, `status-right` right-aligned,
    /// padded between (the same `#[…]`/`#{…}` grammar + tokens as the GUI).
    private func mainStatusLine(ctx: FormatContext) -> [StyledSegment] {
        let leftSegs = FormatString.evaluateStyled(statusOptions["status-left"] ?? "", context: ctx)
        let rightSegs = FormatString.evaluateStyled(statusOptions["status-right"] ?? "", context: ctx)
        let leftWidth = leftSegs.reduce(0) { $0 + $1.text.unicodeScalars.count }
        let rightWidth = rightSegs.reduce(0) { $0 + $1.text.unicodeScalars.count }
        if leftWidth + rightWidth >= cols { return clipSegments(leftSegs, to: cols) }
        var out = leftSegs
        out.append(StyledSegment(text: String(repeating: " ", count: cols - leftWidth - rightWidth)))
        out.append(contentsOf: rightSegs)
        return out
    }

    /// An extra status row (`status-format-<i>`), clipped to width. A blank format yields
    /// an empty row so the band keeps its reserved height.
    private func extraStatusLine(_ format: String, ctx: FormatContext) -> [StyledSegment] {
        clipSegments(FormatString.evaluateStyled(format, context: ctx), to: cols)
    }

    /// Truncate styled segments to a total scalar `width`, cutting the last that overflows.
    private func clipSegments(_ segs: [StyledSegment], to width: Int) -> [StyledSegment] {
        var out: [StyledSegment] = []
        var used = 0
        for seg in segs {
            let count = seg.text.unicodeScalars.count
            if used + count <= width { out.append(seg); used += count; continue }
            let remain = width - used
            if remain > 0 {
                var s = seg
                s.text = String(String.UnicodeScalarView(seg.text.unicodeScalars.prefix(remain)))
                out.append(s)
            }
            break
        }
        return out
    }

    private func currentTarget() -> CommandTarget {
        CommandTarget(
            snapshot: latestSnapshot ?? SessionSnapshot(),
            focusedWorkspaceID: workspaceID,
            focusedTabID: tab.id,
            focusedPaneID: activePaneID,
            markedPaneID: markedPaneID
        )
    }

    private func formatContext(target: CommandTarget) -> FormatContext {
        let order = target.paneOrder
        let paneIndex = activePaneID.flatMap { order.firstIndex(of: $0) }
        let tabIndex = target.session?.tabs.firstIndex(where: { $0.id == tab.id })
        return FormatContext(
            paneID: activePaneID?.uuidString,
            paneTitle: tab.title,
            paneCwd: tab.cwd,
            paneActive: true,
            paneIndex: paneIndex,
            sessionName: target.session?.name,
            tabName: tab.title,
            tabIndex: tabIndex,
            workspaceName: target.workspace?.name,
            agentKind: tab.agent?.kind.rawValue,
            gitBranch: tab.gitBranch,
            clientName: configuration.label,
            windowFlags: windowFlags()
        )
    }

    /// Format context for a *specific* pane (for `pane-border-format`): its index in the
    /// pane order and active state. Harness has no per-pane title, so `pane_title` falls back
    /// to the tab title (matching what the GUI shows).
    private func paneFormatContext(rect: PaneRect, active: Bool) -> FormatContext {
        let target = currentTarget()
        let paneIndex = target.paneOrder.firstIndex(of: rect.paneID)
        let tabIndex = target.session?.tabs.firstIndex(where: { $0.id == tab.id })
        return FormatContext(
            paneID: rect.paneID.uuidString,
            paneTitle: tab.title,
            paneCwd: tab.cwd,
            paneActive: active,
            paneIndex: paneIndex.map { $0 + paneBaseIndex },
            sessionName: target.session?.name,
            tabName: tab.title,
            tabIndex: tabIndex.map { $0 + baseIndex },
            workspaceName: target.workspace?.name,
            agentKind: tab.agent?.kind.rawValue,
            gitBranch: tab.gitBranch,
            clientName: configuration.label,
            windowFlags: windowFlags()
        )
    }

    private func windowFlags() -> String {
        var flags = ""
        if tab.zoomedPaneID != nil { flags += "Z" }
        if markedPaneID != nil { flags += "M" }
        if synchronize { flags += "S" }
        if tab.activity { flags += "#" }
        if tab.silence { flags += "~" }
        if tab.bell || tab.status == .waiting { flags += "!" }
        return flags
    }

    private func clip(_ string: String, to width: Int) -> String {
        let scalars = Array(string.unicodeScalars)
        guard scalars.count > width else { return string }
        return String(String.UnicodeScalarView(scalars.prefix(max(0, width))))
    }

    /// Show a transient message on the status row for ~2s, then revert.
    private func flashStatus(_ message: String) {
        statusOverrideToken += 1
        let token = statusOverrideToken
        statusOverride = message
        compositor.invalidate()
        composeAndWrite()
        renderQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.statusOverrideToken == token else { return }
            self.statusOverride = nil
            self.compositor.invalidate()
            self.composeAndWrite()
        }
    }

    /// Pull the status options the status line needs from the daemon.
    private func refreshStatusOptions() {
        guard case let .options(entries)? = try? client.request(.showOptions(scope: nil), timeout: 1) else { return }
        var resolved: [String: String] = [:]
        // `status`, `status-left`/`-right`/`-center`, and the multi-line `status-format-<i>`
        // rows. A prefix match keeps the multi-line keys without enumerating each.
        for entry in entries where entry.key == "status" || entry.key.hasPrefix("status-") {
            // Prefer a global value; any scope is acceptable as a fallback.
            if resolved[entry.key] == nil || entry.scope == "global" {
                resolved[entry.key] = entry.value
            }
        }
        statusOptions = resolved
        // `window-style`/`pane-style` base colors (global values; per-pane scoping is a
        // refinement left to the GUI which has the pane targets).
        func styleValue(_ key: String) -> String {
            var v = ""
            for entry in entries where entry.key == key {
                if v.isEmpty || entry.scope == "global" { v = entry.value }
            }
            return v
        }
        paneStyles = PaneStyleSet(
            window: styleValue("window-style"),
            windowActive: styleValue("window-active-style"),
            pane: styleValue("pane-style"),
            paneActive: styleValue("pane-active-style")
        )
        paneBorderStatus = PaneBorderStatus(option: styleValue("pane-border-status"))
        // Unset over IPC (show-options omits unseeded builtins) → the shared builtin default.
        let fmt = styleValue("pane-border-format")
        paneBorderFormat = fmt.isEmpty ? (OptionStore.builtinDefaults["pane-border-format"]?.stringValue ?? "") : fmt
        for entry in entries where entry.key == "base-index" { baseIndex = Int(entry.value) ?? baseIndex }
        for entry in entries where entry.key == "pane-base-index" { paneBaseIndex = Int(entry.value) ?? paneBaseIndex }
        for entry in entries where entry.key == "mode-keys" { modeKeys = entry.value }
        for entry in entries where entry.key == "set-clipboard" { allowClipboard = entry.value != "off" && entry.value != "false" }
        for entry in entries where entry.key == "mouse" {
            let on = entry.value == "on" || entry.value == "true" || entry.value == "1"
            if on != mouseEnabled { mouseEnabled = on; setOuterMouseTracking(on) }
        }
    }

    /// Enable/disable SGR mouse tracking on the *outer* terminal so the compositor receives
    /// mouse reports it can demux to panes (tmux `mouse on`). Off restores normal selection.
    private func setOuterMouseTracking(_ on: Bool) {
        writeOut(on ? "\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1006h" : "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1006l")
    }

    // MARK: Input

    // Input state, held across reads so split escape/mouse sequences decode correctly.
    private var inPrefix = false
    private var prefixPending: [UInt8] = []
    /// `switch-client -T <table>`: the key table for the next armed key (modal bindings).
    /// One-shot — consulted instead of `.prefix`, then cleared (unless its command switches
    /// again). Like all input/mode state it is touched only on `renderQueue` (consumeInput and
    /// every command path run there), so no cross-thread synchronization is needed.
    private var pendingTable: KeyTableID?
    private var copyModePending: [UInt8] = []
    private var mouseSeq: [UInt8] = []
    private var collectingMouse = false
    // `bind -n` root table (no-prefix bindings): buffer a candidate command key (control
    // byte / ESC sequence) and look it up in `.root`. Only engaged when the user actually
    // has root bindings, so plain typing and unbound control keys still forward verbatim.
    private var inRoot = false
    private var rootPending: [UInt8] = []
    private lazy var hasRootBindings = !(keyTables.table(.root)?.bindings.isEmpty ?? true)

    private func runInputLoop() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var fds: [pollfd] = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]

        while !shouldExit() {
            let ready = fds.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), -1) }
            if ready < 0 { if errno == EINTR { continue }; break }
            if (fds[1].revents & Int16(POLLIN)) != 0 {
                var drain = [UInt8](repeating: 0, count: 32)
                _ = read(wakeRead, &drain, drain.count)
                continue
            }
            guard (fds[0].revents & Int16(POLLIN)) != 0 else { continue }
            let n = read(STDIN_FILENO, &buffer, buffer.count)
            if n == 0 { break }
            if n < 0 { if errno == EINTR { continue }; break }

            // The input thread only reads bytes; ALL decode + state inspection runs on
            // renderQueue, which is the single owner of every piece of input/mode/layout state
            // (inPrefix, prefixPending, pendingTable, copyMode, rects, activeSurface, …). This
            // makes those accesses single-threaded — no data races between stdin and renders.
            let chunk = Array(buffer[0 ..< n])
            renderQueue.async { [weak self] in
                guard let self else { return }
                var forward = Data()
                for byte in chunk { self.consumeInput(byte, forward: &forward) }
                if !forward.isEmpty { self.dispatchForward(forward) }
            }
        }
    }

    /// Process one input byte: prefix machine → copy mode → SGR mouse → pane forward.
    private func consumeInput(_ byte: UInt8, forward: inout Data) {
        let prefix = configuration.prefix

        if inPrefix {
            prefixPending.append(byte)
            switch Self.decodeKeySpec(prefixPending) {
            case .incomplete:
                return
            case .literalPrefix:
                forward.append(prefix)
                prefixPending.removeAll(keepingCapacity: true); inPrefix = false; pendingTable = nil
            case let .complete(spec):
                if !handleBoundKey(spec) {
                    forward.append(prefix)
                    forward.append(contentsOf: prefixPending)
                }
                prefixPending.removeAll(keepingCapacity: true)
                // A `switch-client -T` binding leaves `pendingTable` set — stay armed so the
                // next key decodes in that table instead of exiting prefix mode.
                inPrefix = (pendingTable != nil)
            case .invalid:
                forward.append(prefix)
                forward.append(contentsOf: prefixPending)
                prefixPending.removeAll(keepingCapacity: true); inPrefix = false; pendingTable = nil
            }
            return
        }
        // Mid-decode of a `bind -n` root sequence (e.g. ESC [ 1 ; 3 D for M-Left).
        if inRoot {
            feedRoot(byte, forward: &forward)
            return
        }
        if byte == prefix {
            inPrefix = true
            prefixPending.removeAll(keepingCapacity: true)
            return
        }

        // Copy mode consumes everything except the prefix. (Direct call — consumeInput already
        // runs on renderQueue, so a nested async would risk reordering against the next chunk.)
        if copyMode != nil {
            handleCopyModeByte(byte)
            return
        }

        // SGR mouse reports (`ESC [ < … M/m`) from the outer terminal, when mouse is on.
        if mouseEnabled {
            if collectingMouse {
                mouseSeq.append(byte)
                if byte == UInt8(ascii: "M") || byte == UInt8(ascii: "m") {
                    let seq = mouseSeq; mouseSeq.removeAll(keepingCapacity: true); collectingMouse = false
                    handleMouse(seq)
                } else if mouseSeq.count > 32 {
                    mouseSeq.removeAll(keepingCapacity: true); collectingMouse = false
                }
                return
            }
            if !mouseSeq.isEmpty {
                mouseSeq.append(byte)
                if Array(SGRMouse.prefix.prefix(mouseSeq.count)) == mouseSeq {
                    if mouseSeq.count == SGRMouse.prefix.count { collectingMouse = true }
                    return
                }
                forward.append(contentsOf: mouseSeq) // not a mouse sequence after all
                mouseSeq.removeAll(keepingCapacity: true)
                return
            }
            if byte == 0x1b { mouseSeq = [byte]; return }
        }

        // display-panes overlay: a digit selects that pane; any other key dismisses it.
        if showPaneNumbers {
            if byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
                let digit = Int(byte - UInt8(ascii: "0"))
                selectPaneByDisplayIndex(digit)
                return
            }
            dismissPaneNumbers()
        }

        // `bind -n` root table: a control byte / ESC sequence may be a no-prefix binding.
        // ESC only reaches here with the mouse off (the mouse demux claims ESC above), so
        // bind -n on modified arrows needs `mouse off` — the common attach case.
        if hasRootBindings, Self.isRootCandidate(byte) {
            feedRoot(byte, forward: &forward)
            return
        }

        forward.append(byte)
    }

    /// Bytes that could begin a `.root` key: control bytes (C-x) and ESC sequences
    /// (M-x / modified arrows). Plain printable input is never buffered for root.
    private static func isRootCandidate(_ byte: UInt8) -> Bool {
        (byte >= 0x01 && byte <= 0x1a) || byte == 0x1b || byte == 0x7f
    }

    /// Buffer + decode a candidate root key; run its `.root` binding if bound, else forward
    /// the buffered bytes verbatim. Mirrors the prefix machine (tolerant of split reads).
    private func feedRoot(_ byte: UInt8, forward: inout Data) {
        rootPending.append(byte)
        switch Self.decodeKeySpec(rootPending) {
        case .incomplete:
            inRoot = true
        case let .complete(spec):
            if !handleRootKey(spec) { forward.append(contentsOf: rootPending) }
            rootPending.removeAll(keepingCapacity: true); inRoot = false
        case .invalid, .literalPrefix:
            forward.append(contentsOf: rootPending)
            rootPending.removeAll(keepingCapacity: true); inRoot = false
        }
    }

    /// Look a `KeySpec` up in the `.root` (no-prefix) table and run its `Command`.
    private func handleRootKey(_ spec: KeySpec) -> Bool {
        guard let binding = keyTables.table(.root)?.lookup(spec) else { return false }
        let command = binding.command
        renderQueue.async { [weak self] in self?.execute(command) }
        return true
    }

    /// Send forwarded bytes to the focused pane — or to every pane when synchronized.
    private func dispatchForward(_ data: Data) {
        if synchronize {
            for rect in rects {
                _ = try? client.request(.sendData(surfaceID: rect.surfaceID.uuidString, data: data), timeout: 1)
            }
        } else if let active = activeSurface {
            _ = try? client.request(.sendData(surfaceID: active, data: data), timeout: 1)
        }
    }

    /// The active pane's id (for IPC ops that target a specific pane).
    private var activePaneID: PaneID? {
        guard let activeSurface else { return rects.first?.paneID }
        return rects.first(where: { $0.surfaceID.uuidString == activeSurface })?.paneID
    }

    // MARK: Copy mode (compositor) — runs on renderQueue

    /// Re-solve the pane rects if the status band changed size (e.g. copy mode adds a status
    /// row when `status` is off). Cheap — existing terminals just resize, no re-subscribe.
    private func relayoutIfStatusBandChanged() {
        if reservedStatusRows() != reservedStatus { rebuildLayout(initial: false) }
    }

    private func enterCopyMode() {
        guard let surface = activeSurface, let term = terminals[surface] else { return }
        copyModeSurface = surface
        let live = term.readGrid()
        let cursorLine = term.historyCount + (live?.cursor.row ?? 0)
        copyMode = CopyModeReducer.initialState(grid: term, cursorLine: cursorLine, cursorColumn: live?.cursor.col ?? 0)
        copyModePending.removeAll(); copyModeSearchEntry = nil
        relayoutIfStatusBandChanged()
        compositor.invalidate(); composeAndWrite()
    }

    private func exitCopyMode() {
        copyMode = nil; copyModeSurface = nil; copyModeSearchEntry = nil; copyModePending.removeAll()
        relayoutIfStatusBandChanged()
        compositor.invalidate(); composeAndWrite()
    }

    private func focusedCopyGrid() -> HarnessGridTerminal? {
        guard let s = copyModeSurface else { return nil }
        return terminals[s]
    }

    private func handleCopyModeByte(_ byte: UInt8) {
        guard copyMode != nil else { return }
        if copyModeSearchEntry != nil { handleCopyModeSearchByte(byte); return }
        copyModePending.append(byte)
        switch copyModeDecode(copyModePending) {
        case .incomplete:
            return
        case let .complete(spec):
            copyModePending.removeAll(keepingCapacity: true)
            if let table = keyTables.table(KeyTableID.copyMode(modeKeys: modeKeys)),
               case let .copyModeCommand(action)? = table.lookup(spec)?.command {
                performCopyMode(action)
            }
        case .literalPrefix, .invalid:
            copyModePending.removeAll(keepingCapacity: true)
        }
    }

    private func handleCopyModeSearchByte(_ byte: UInt8) {
        switch byte {
        case 0x0d, 0x03: // Enter — commit the search
            let query = copyModeSearchEntry ?? ""
            copyModeSearchEntry = nil
            if let cm = copyMode, let grid = focusedCopyGrid(), !query.isEmpty {
                copyMode = CopyModeReducer.applySearch(cm, query: query, reverse: cm.search.reverse, grid: grid)
            }
            compositor.invalidate(); composeAndWrite()
        case 0x1b: // Escape — abandon
            copyModeSearchEntry = nil
            compositor.invalidate(); composeAndWrite()
        case 0x7f, 0x08: // Backspace
            if var q = copyModeSearchEntry, !q.isEmpty { q.removeLast(); copyModeSearchEntry = q }
            composeAndWrite()
        default:
            if byte >= 0x20, byte < 0x7f {
                copyModeSearchEntry = (copyModeSearchEntry ?? "") + String(Unicode.Scalar(byte))
            }
            composeAndWrite()
        }
    }

    /// Decode copy-mode input bytes into a `KeySpec` — like `decodeKeySpec` but mapping the
    /// special single bytes (Enter / Backspace / Tab / Space) to their named keys.
    private func copyModeDecode(_ bytes: [UInt8]) -> KeySpecDecode {
        if bytes.count == 1 {
            switch bytes[0] {
            case 0x0d, 0x03: return .complete(KeySpec(key: "Enter"))
            case 0x7f, 0x08: return .complete(KeySpec(key: "Backspace"))
            case 0x09: return .complete(KeySpec(key: "Tab"))
            case 0x20: return .complete(KeySpec(key: "Space"))
            case 0x1b: return .incomplete // may begin a CSI/arrow sequence
            default: break
            }
        }
        return Self.decodeKeySpec(bytes)
    }

    private func performCopyMode(_ action: CopyModeAction) {
        guard let cm = copyMode, let grid = focusedCopyGrid() else { return }
        let (next, effect) = CopyModeReducer.reduce(cm, action, grid: grid)
        copyMode = next
        switch effect {
        case .none:
            compositor.invalidate(); composeAndWrite()
        case let .copy(text):
            writeCopyBuffer(text); compositor.invalidate(); composeAndWrite()
        case let .copyAndCancel(text):
            writeCopyBuffer(text); exitCopyMode()
        case let .pipe(text, command):
            runCopyPipe(text: text, command: command); exitCopyMode()
        case .paste:
            exitCopyMode(); pasteBufferIntoActive()
        case .cancel:
            exitCopyMode()
        case .beginSearchEntry:
            copyModeSearchEntry = ""; composeAndWrite()
        }
    }

    private func copyModeStatusLine() -> String? {
        guard let cm = copyMode else { return nil }
        if let entry = copyModeSearchEntry { return clip((cm.search.reverse ? "?" : "/") + entry, to: cols) }
        return clip(cm.statusLine() + (synchronize ? "  [sync]" : ""), to: cols)
    }

    /// Yank: set the client's own clipboard via OSC 52 (gated on `set-clipboard`) and mirror
    /// into the daemon buffer so the GUI and other clients see the same yank.
    private func writeCopyBuffer(_ text: String) {
        guard !text.isEmpty else { return }
        if allowClipboard {
            writeOut("\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}")
        }
        if let data = text.data(using: .utf8) {
            _ = try? client.request(.setBuffer(name: nil, data: data), timeout: 1)
        }
    }

    private func runCopyPipe(text: String, command: String) {
        guard !text.isEmpty, !command.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        let pipe = Pipe()
        p.standardInput = pipe
        if (try? p.run()) != nil {
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try? pipe.fileHandleForWriting.close()
        }
    }

    private func pasteBufferIntoActive() {
        guard let active = activeSurface else { return }
        _ = try? client.request(.pasteBuffer(surfaceID: active, name: nil, bracketed: false), timeout: 1)
    }

    /// OSC 52 from a pane's program → the client's clipboard + the daemon buffer. Already on
    /// `renderQueue` (fired synchronously while feeding the terminal).
    private func handleProgramClipboard(_ text: String, surface: String) {
        guard allowClipboard, !text.isEmpty else { return }
        writeOut("\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}")
        if let data = text.data(using: .utf8) {
            _ = try? client.request(.setBuffer(name: nil, data: data), timeout: 1)
        }
    }

    // MARK: Mouse (SGR 1006) — runs on renderQueue

    private func handleMouse(_ seq: [UInt8]) {
        guard let e = SGRMouse.parse(seq),
              let route = SGRMouse.route(column: e.column, row: e.row, rects: rects),
              route.index < rects.count else { return }
        let rect = rects[route.index]
        let sid = rect.surfaceID.uuidString
        // A non-wheel press focuses the pane (server-authoritative).
        if !e.release, !e.motion, !e.wheel, sid != activeSurface {
            activeSurface = sid
            _ = try? client.request(.selectPane(tabID: tab.id, paneID: rect.paneID), timeout: 1)
            compositor.invalidate(); composeAndWrite()
        }
        // Forward re-based to the pane only if its program enabled mouse tracking.
        guard let term = terminals[sid], term.modes.mouseTrackingEnabled else { return }
        let bytes = InputEncoder().encodeMouse(
            button: mouseButton(e), kind: mouseKind(e),
            column: route.localColumn, row: route.localRow,
            modifiers: mouseModifiers(e), modes: term.modes
        )
        if !bytes.isEmpty { _ = try? client.request(.sendData(surfaceID: sid, data: Data(bytes)), timeout: 1) }
    }

    private func mouseButton(_ e: SGRMouseEvent) -> MouseButton {
        if e.wheel { return e.button == 0 ? .wheelUp : .wheelDown }
        switch e.button { case 1: return .middle; case 2: return .right; default: return .left }
    }

    private func mouseKind(_ e: SGRMouseEvent) -> MouseEventKind {
        if e.release { return .release }
        if e.motion { return .drag }
        return .press
    }

    private func mouseModifiers(_ e: SGRMouseEvent) -> KeyModifiers {
        var m: KeyModifiers = []
        if e.shift { m.insert(.shift) }
        if e.meta { m.insert(.option) }
        if e.control { m.insert(.control) }
        return m
    }

    // MARK: synchronize-panes / display-panes — runs on renderQueue

    private func toggleSynchronize(_ set: Bool?) {
        synchronize = set ?? !synchronize
        flashStatus(synchronize ? "synchronize-panes on" : "synchronize-panes off")
    }

    private func showDisplayPanes() {
        showPaneNumbers = true
        displayPanesToken += 1
        let token = displayPanesToken
        compositor.invalidate(); composeAndWrite()
        renderQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.displayPanesToken == token else { return }
            self.dismissPaneNumbers()
        }
    }

    private func dismissPaneNumbers() {
        guard showPaneNumbers else { return }
        showPaneNumbers = false
        compositor.invalidate(); composeAndWrite()
    }

    private func selectPaneByDisplayIndex(_ index: Int) {
        showPaneNumbers = false
        let pos = index - paneBaseIndex
        if pos >= 0, pos < rects.count {
            let rect = rects[pos]
            activeSurface = rect.surfaceID.uuidString
            _ = try? client.request(.selectPane(tabID: tab.id, paneID: rect.paneID), timeout: 1)
        }
        compositor.invalidate(); composeAndWrite()
    }

    /// Pane-number labels drawn at each pane's center (emitted after the composited frame).
    private func paneNumbersOverlay() -> String {
        var out = ""
        for (i, rect) in rects.enumerated() {
            let label = "\(paneBaseIndex + i)"
            let cx = rect.x + max(0, rect.cols / 2 - label.count / 2)
            let cy = rect.y + rect.rows / 2
            guard cx >= 0, cx < cols, cy >= 0, cy < rows else { continue }
            out += "\u{1b}[\(cy + 1);\(cx + 1)H\u{1b}[1;7m\(label)\u{1b}[0m"
        }
        return out
    }

    // MARK: Prefix → KeySpec → Command → IPC

    enum KeySpecDecode: Equatable {
        case complete(KeySpec)
        case incomplete
        case literalPrefix
        case invalid
    }

    /// Decode the bytes captured after the prefix into a single `KeySpec`. Handles
    /// printable keys, `C-<letter>` control bytes, `M-<key>` (ESC-prefixed), and the
    /// CSI/SS3 arrow keys with xterm modifier encodings — so the prefix table's
    /// `Up`/`S-Left`/… bindings resolve over a raw TTY, including split reads.
    static func decodeKeySpec(_ bytes: [UInt8]) -> KeySpecDecode {
        guard let first = bytes.first else { return .incomplete }
        if first == 0x01 && bytes.count == 1 { return .literalPrefix }

        if first == 0x1b { // ESC
            if bytes.count == 1 { return .incomplete }
            let second = bytes[1]
            if second == UInt8(ascii: "[") || second == UInt8(ascii: "O") {
                return decodeCSI(bytes)
            }
            if let scalar = printableScalar(second) {
                return .complete(KeySpec(key: String(scalar), modifiers: .option))
            }
            return .invalid
        }

        // Control bytes 0x01–0x1a → C-a … C-z. (A leading prefix byte is consumed
        // before we ever get here, so 0x01 only reaches this as a command key.)
        if first >= 0x01 && first <= 0x1a {
            let letter = Character(UnicodeScalar(first + 0x60))
            return .complete(KeySpec(key: String(letter), modifiers: .control))
        }
        if first == 0x7f { return .complete(KeySpec(key: "BSpace")) }
        if let scalar = printableScalar(first) {
            return .complete(KeySpec(key: String(scalar)))
        }
        return .invalid
    }

    private static func decodeCSI(_ bytes: [UInt8]) -> KeySpecDecode {
        // Forms: ESC [ A  |  ESC O A  |  ESC [ 1 ; <mod> <letter>
        guard bytes.count >= 3 else { return .incomplete }
        func arrowKey(_ b: UInt8) -> String? {
            switch b {
            case UInt8(ascii: "A"): return "Up"
            case UInt8(ascii: "B"): return "Down"
            case UInt8(ascii: "C"): return "Right"
            case UInt8(ascii: "D"): return "Left"
            default: return nil
            }
        }
        let third = bytes[2]
        if let key = arrowKey(third) { return .complete(KeySpec(key: key)) }
        if third == UInt8(ascii: "1") {
            guard bytes.count >= 4 else { return .incomplete }
            guard bytes[3] == UInt8(ascii: ";") else { return .invalid }
            guard bytes.count >= 6 else { return .incomplete }
            guard let key = arrowKey(bytes[5]) else { return .invalid }
            return .complete(KeySpec(key: key, modifiers: modifiers(fromXtermCode: bytes[4])))
        }
        return .invalid
    }

    private static func modifiers(fromXtermCode code: UInt8) -> KeySpec.Modifiers {
        // xterm: code = 1 + (shift=1 | alt=2 | ctrl=4). "2"=shift, "3"=alt, "5"=ctrl, "6"=ctrl+shift.
        let value = Int(code) - Int(UInt8(ascii: "0")) - 1
        var mods = KeySpec.Modifiers()
        if value & 1 != 0 { mods.insert(.shift) }
        if value & 2 != 0 { mods.insert(.option) }
        if value & 4 != 0 { mods.insert(.control) }
        return mods
    }

    private static func printableScalar(_ byte: UInt8) -> Unicode.Scalar? {
        (byte >= 0x20 && byte < 0x7f) ? Unicode.Scalar(byte) : nil
    }

    /// Look a `KeySpec` up in the merged prefix table and run its `Command`.
    /// Returns false if nothing is bound (caller forwards the bytes verbatim).
    private func handleBoundKey(_ spec: KeySpec) -> Bool {
        let table = pendingTable ?? .prefix
        pendingTable = nil
        guard let binding = keyTables.table(table)?.lookup(spec) else { return false }
        let command = binding.command
        // A table switch is resolved synchronously on the input thread so the next byte
        // re-enters prefix decoding in the new table (no thread hop, no race).
        if case let .switchClientTable(name) = command {
            pendingTable = KeyTableID(rawValue: name)
            return true
        }
        renderQueue.async { [weak self] in self?.execute(command) }
        return true
    }

    /// Translate a `Command` to IPC through the shared `CommandIPCTranslator` and
    /// run it, or handle the client-local verbs here. Runs on `renderQueue`.
    private func execute(_ command: Command) {
        if case let .sequence(commands) = command {
            for sub in commands { execute(sub) }
            return
        }
        guard case let .snapshot(snapshot)? = try? client.request(.getSnapshot, timeout: 1) else { return }
        latestSnapshot = snapshot
        let target = CommandTarget(
            snapshot: snapshot,
            focusedWorkspaceID: workspaceID,
            focusedTabID: tab.id,
            focusedPaneID: activePaneID,
            markedPaneID: markedPaneID
        )
        switch CommandIPCTranslator.translate(command, target: target, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex) {
        case let .requests(requests):
            for request in requests { _ = try? client.request(request, timeout: 2) }
            checkStructure()
        case let .clientLocal(local):
            handleLocalCommand(local, target: target)
        case .unresolved:
            break
        }
    }

    /// The client-local verbs the translator hands back: detach, marked-pane
    /// tracking, and a transient status message. Modes the compositor renders in
    /// later phases (copy-mode/synchronize/display-panes) are intentional no-ops
    /// here rather than leaking stray bytes to the focused pane.
    private func handleLocalCommand(_ command: Command, target: CommandTarget) {
        switch command {
        case .detachClient:
            requestDetach()
        case let .markPane(set):
            markedPaneID = set ? activePaneID : nil
            flashStatus(set ? "marked pane" : "marked pane cleared")
        case let .displayMessage(format):
            flashStatus(FormatString.evaluate(format, context: formatContext(target: target)))
        case .sendPrefix:
            if let active = activeSurface {
                _ = try? client.request(.sendData(surfaceID: active, data: Data([configuration.prefix])), timeout: 1)
            }
        case .copyMode:
            if copyMode != nil { exitCopyMode() } else { enterCopyMode() }
        case let .copyModeCommand(action):
            if copyMode != nil { performCopyMode(action) }
        case let .synchronizePanes(set):
            toggleSynchronize(set)
        case .displayPanes:
            showDisplayPanes()
        case let .switchClientTable(name):
            // Reached from a `.root`/command-prompt/hook invocation (the prefix path resolves it
            // in handleBoundKey). Arm the next key; safe because this and consumeInput both run
            // on renderQueue.
            pendingTable = KeyTableID(rawValue: name)
            inPrefix = true
            prefixPending.removeAll(keepingCapacity: true)
        case .showCheatsheet, .sourceConfig, .reloadKeybindings, .bindKey, .unbindKey, .listKeys,
             .renameWindow, .renameSession, .runShell, .ifShell:
            break
        default:
            break
        }
    }

    // MARK: Structure changes

    /// Subscribe to daemon snapshot pushes — re-check structure on every layout commit,
    /// instead of the old 0.5s poll. The push is the mechanism; `onEnd` (daemon gone /
    /// socket closed) falls through to detach via the next structure check.
    private func installSnapshotSubscription() {
        snapshotSubscription = try? client.subscribeSnapshot(
            label: "attach-window",
            onRevision: { [weak self] _ in self?.scheduleStructureCheck() },
            onEnd: { [weak self] in self?.scheduleStructureCheck() }
        )
    }

    private func scheduleStructureCheck() {
        renderQueue.async { [weak self] in self?.checkStructure() }
    }

    /// Re-fetch the snapshot and follow the session's active window. If the
    /// session focuses a different tab (GUI switch, `next-window`, new tab) we
    /// re-pin to it; otherwise we rebuild only when the focused tab's structure,
    /// zoom, title, or active pane changed. Runs on `renderQueue`.
    private func checkStructure() {
        // A push also fires on `set-option` (the daemon nudges subscribers), so re-pull options
        // every time — this is how a runtime status-*/mouse/pane-style/mode-keys change reaches
        // an attached client. Then re-solve if the status band size changed but structure didn't.
        refreshStatusOptions()
        relayoutIfStatusBandChanged()

        guard case let .snapshot(snapshot)? = try? client.request(.getSnapshot, timeout: 1) else { return }
        latestSnapshot = snapshot
        guard let session = WindowAttachClient.session(snapshot, id: sessionID) else {
            requestDetach()   // session destroyed
            return
        }
        // Follow the session's focused window (or fall back to its first tab).
        let focused = session.tabs.first(where: { $0.id == session.activeTabID }) ?? session.tabs.first
        guard let latest = focused else {
            requestDetach()   // session has no tabs left
            return
        }
        let changed = latest.id != tab.id
            || latest.rootPane != tab.rootPane
            || latest.zoomedPaneID != tab.zoomedPaneID
            || latest.title != tab.title
            || latest.activePaneID != tab.activePaneID
        if changed {
            tab = latest
            rebuildLayout(initial: false)
        } else {
            // No structural change, but a status-left/right/format edit still needs a repaint.
            compositor.invalidate(); composeAndWrite()
        }
    }

    // MARK: Plumbing

    private func writeOut(_ string: String) {
        let data = Data(string.utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(STDOUT_FILENO, base.advanced(by: written), raw.count - written)
                if n > 0 { written += n; continue }
                if n < 0, errno == EINTR { continue }
                return
            }
        }
    }

    private func installWakePipe() throws {
        var fds: [Int32] = [-1, -1]
        guard fds.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0 else {
            throw NSError(domain: "WindowAttachClient", code: 1, userInfo: [NSLocalizedDescriptionKey: "pipe() failed"])
        }
        wakeRead = fds[0]; wakeWrite = fds[1]
        _ = fcntl(wakeWrite, F_SETFL, fcntl(wakeWrite, F_GETFL) | O_NONBLOCK)
    }

    private func installSignalHandlers() {
        signal(SIGWINCH, SIG_IGN)
        let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: renderQueue)
        winch.setEventHandler { [weak self] in self?.rebuildLayout(initial: false) }
        winch.resume()
        sigwinch = winch

        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        term.setEventHandler { [weak self] in self?.requestDetach() }
        term.resume()
        sigterm = term
    }

    private func shouldExit() -> Bool {
        detachLock.lock(); defer { detachLock.unlock() }
        return detachRequested
    }

    private func requestDetach() {
        detachLock.lock()
        let already = detachRequested
        detachRequested = true
        detachLock.unlock()
        guard !already, wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    private func teardown() {
        // Stop new render work from being enqueued before draining the queue.
        snapshotSubscription?.cancel()
        sigwinch?.cancel()
        sigterm?.cancel()
        for sub in subscriptions { sub.cancel() }
        for sid in terminals.keys {
            _ = try? client.request(.detachSurface(surfaceID: sid), timeout: 1)
        }
        // Drain any in-flight render, block future ones, then emit the cleanup sequence as the
        // single final stdout write — so it never interleaves with a composeAndWrite.
        renderQueue.sync {
            tornDown = true
            if mouseEnabled { setOuterMouseTracking(false) }
            writeOut("\u{1b}[0m\u{1b}[?25h\u{1b}[2J\u{1b}[H") // reset SGR, show cursor, clear frame
        }
        if wakeRead >= 0 { close(wakeRead) }
        if wakeWrite >= 0 { close(wakeWrite) }
    }
}

extension WindowAttachClient {
    static func resolveTabByID(_ snapshot: SessionSnapshot, id: TabID) -> Tab? {
        for ws in snapshot.workspaces {
            for sess in ws.sessions {
                if let t = sess.tabs.first(where: { $0.id == id }) { return t }
            }
        }
        return nil
    }

    static func session(_ snapshot: SessionSnapshot, id: SessionID) -> SessionGroup? {
        for ws in snapshot.workspaces {
            if let s = ws.sessions.first(where: { $0.id == id }) { return s }
        }
        return nil
    }
}
