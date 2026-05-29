import Darwin
import Foundation
import GhosttyTerminal
import HarnessCore
import HarnessTerminalKit

/// Renders a daemon-owned **window** (a tab's full split layout) into a plain
/// terminal — the headline `harness attach` compositor. Unlike `AttachClient`
/// (single-pane passthrough), this lays out every pane with borders, emulates
/// each pane's screen locally with a renderer-free `GridTerminal`, and paints a
/// composited frame via `GridCompositor`.
///
/// Architecture (client-side emulation, the same shape the GUI uses): the
/// daemon stays a dumb PTY byte pipe. Per pane we `subscribeSurfaceOutput` +
/// `replayScrollback`, feed the bytes into a `GridTerminal`, read its styled
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
    /// A transient status override (e.g. `display-message`), shown briefly.
    private var statusOverride: String?
    private var statusOverrideToken = 0
    /// Current composited dimensions (kept for status-line right-alignment).
    private var cols = 80
    private var rows = 24

    /// All pane work — feeding GridTerminals, compositing, writing stdout —
    /// runs on this serial queue. GridTerminal is not thread-safe, so every
    /// access is funneled here.
    private let renderQueue = DispatchQueue(label: "harness.window.render")
    private var terminals: [String: GridTerminal] = [:]
    private var subscriptions: [DaemonSubscription] = []
    private var rects: [PaneRect] = []
    private var compositor: GridCompositor
    private var activeSurface: String?
    private var renderScheduled = false

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

        let contentRows = max(1, rows - 1) // reserve a status row

        // Compute rects. A zoomed pane takes the whole content area.
        if let zoomed = tab.zoomedPaneID, let leaf = findLeaf(tab.rootPane, paneID: zoomed) {
            rects = [PaneRect(paneID: leaf.id, surfaceID: leaf.surfaceID, x: 0, y: 0, cols: cols, rows: contentRows)]
        } else {
            rects = PaneRectSolver.solve(tab.rootPane, cols: cols, rows: contentRows)
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
                guard let term = GridTerminal(cols: rect.cols, rows: rect.rows) else { continue }
                terminals[sid] = term
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
            self.scheduleRender()
        }
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
        var panes: [CompositorPane] = []
        panes.reserveCapacity(rects.count)
        for rect in rects {
            let sid = rect.surfaceID.uuidString
            guard let grid = terminals[sid]?.readGrid() else { continue }
            panes.append(CompositorPane(rect: rect, grid: grid, isActive: sid == activeSurface))
        }
        let ansi = compositor.render(panes: panes, status: statusLine())
        writeOut(ansi)
    }

    /// The status row, evaluated through `FormatString` against the daemon's
    /// `status-left`/`status-right` options (same tokens as the GUI status line),
    /// right-aligning the right segment. A transient `display-message` override
    /// wins while active. Returns nil to hide the row when `status off`.
    private func statusLine() -> String? {
        if let statusOverride { return clip(statusOverride, to: cols) }
        if (statusOptions["status"] ?? "on") == "off" { return nil }
        let ctx = formatContext(target: currentTarget())
        let left = FormatString.evaluate(statusOptions["status-left"] ?? "", context: ctx)
        let right = FormatString.evaluate(statusOptions["status-right"] ?? "", context: ctx)
        return composeStatus(left: left, right: right, width: cols)
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

    private func windowFlags() -> String {
        var flags = ""
        if tab.zoomedPaneID != nil { flags += "Z" }
        if markedPaneID != nil { flags += "M" }
        if tab.status == .waiting { flags += "!" }
        return flags
    }

    /// Left text + right text on one row of `width`, right segment flush-right,
    /// truncated to fit (left wins if they would collide).
    private func composeStatus(left: String, right: String, width: Int) -> String {
        guard width > 0 else { return "" }
        let l = Array(left.unicodeScalars)
        let r = Array(right.unicodeScalars)
        if l.count + r.count >= width {
            return clip(left, to: width)
        }
        let gap = String(repeating: " ", count: width - l.count - r.count)
        return left + gap + right
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
        for entry in entries where ["status", "status-left", "status-right"].contains(entry.key) {
            // Prefer a global value; any scope is acceptable as a fallback.
            if resolved[entry.key] == nil || entry.scope == "global" {
                resolved[entry.key] = entry.value
            }
        }
        statusOptions = resolved
    }

    // MARK: Input

    private func runInputLoop() {
        let prefix = configuration.prefix
        var pending: [UInt8] = []   // bytes captured after the prefix, awaiting a full KeySpec
        var inPrefix = false
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

            var forward = Data()
            var i = 0
            while i < n {
                let byte = buffer[i]; i += 1

                if inPrefix {
                    pending.append(byte)
                    switch Self.decodeKeySpec(pending) {
                    case .incomplete:
                        continue   // escape sequence still arriving (handles split reads)
                    case .literalPrefix:
                        forward.append(prefix)   // prefix prefix → one literal prefix
                        pending.removeAll(keepingCapacity: true); inPrefix = false
                    case let .complete(spec):
                        if !handleBoundKey(spec) {
                            forward.append(prefix)            // unbound → pass through verbatim
                            forward.append(contentsOf: pending)
                        }
                        pending.removeAll(keepingCapacity: true); inPrefix = false
                    case .invalid:
                        forward.append(prefix)
                        forward.append(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true); inPrefix = false
                    }
                    continue
                }

                if byte == prefix {
                    inPrefix = true
                    pending.removeAll(keepingCapacity: true)
                    continue
                }

                forward.append(byte)
            }

            if !forward.isEmpty, let active = activeSurface {
                _ = try? client.request(.sendData(surfaceID: active, data: forward), timeout: 1)
            }
        }
    }

    /// The active pane's id (for IPC ops that target a specific pane).
    private var activePaneID: PaneID? {
        guard let activeSurface else { return rects.first?.paneID }
        return rects.first(where: { $0.surfaceID.uuidString == activeSurface })?.paneID
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
        guard let binding = keyTables.table(.prefix)?.lookup(spec) else { return false }
        let command = binding.command
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
        switch CommandIPCTranslator.translate(command, target: target) {
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
        case .copyMode, .synchronizePanes, .displayPanes, .showCheatsheet,
             .sourceConfig, .reloadKeybindings, .bindKey, .unbindKey, .listKeys,
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
        snapshotSubscription?.cancel()
        sigwinch?.cancel()
        sigterm?.cancel()
        for sub in subscriptions { sub.cancel() }
        for sid in terminals.keys {
            _ = try? client.request(.detachSurface(surfaceID: sid), timeout: 1)
        }
        // Restore the cursor and clear our composited frame.
        writeOut("\u{1b}[0m\u{1b}[?25h\u{1b}[2J\u{1b}[H")
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
