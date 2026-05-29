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
        case id(String)
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
        let client = DaemonClient()
        guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
            fputs("harness-cli attach-window: could not read session snapshot\n", stderr)
            return 1
        }
        guard let tab = resolveTab(snapshot, selector: selector) else {
            fputs("harness-cli attach-window: no matching tab\n", stderr)
            return 1
        }

        let original = AttachClient.enterRawMode()
        defer { AttachClient.restoreTerminalMode(original) }

        let session = WindowSession(client: client, tab: tab, configuration: configuration)
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
        }
    }
}

// MARK: - Window session

private final class WindowSession: @unchecked Sendable {
    private let client: DaemonClient
    private let configuration: WindowAttachClient.Configuration
    private var tab: Tab

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
    private var pollTimer: DispatchSourceTimer?

    init(client: DaemonClient, tab: Tab, configuration: WindowAttachClient.Configuration) {
        self.client = client
        self.tab = tab
        self.configuration = configuration
        let size = AttachClient.ttySize()
        self.compositor = GridCompositor(cols: Int(size?.cols ?? 80), rows: Int(size?.rows ?? 24))
    }

    func run() throws {
        try installWakePipe()
        installSignalHandlers()
        renderQueue.sync { rebuildLayout(initial: true) }
        installStructurePoll()
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

        if activeSurface == nil || !wanted.contains(activeSurface!) {
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

    private func statusLine() -> String {
        let title = tab.title.isEmpty ? "harness" : tab.title
        return " harness  \(title)  [\(rects.count) pane\(rects.count == 1 ? "" : "s")]  ^A d detach  ^A o next-pane "
    }

    // MARK: Input

    private func runInputLoop() {
        let detachSeq = configuration.detachSequence
        let prefix = configuration.prefix
        var matched = 0
        var awaitingPrefixCommand = false
        var buffer = [UInt8](repeating: 0, count: 4096)
        var fds: [pollfd] = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0),
        ]

        loop: while !shouldExit() {
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

                if awaitingPrefixCommand {
                    awaitingPrefixCommand = false
                    if handlePrefixCommand(byte) { continue }
                    // Not a recognized command: send the prefix then this byte.
                    forward.append(prefix)
                    forward.append(byte)
                    continue
                }

                // Detach sequence (prefix + d) takes priority.
                if byte == detachSeq[matched] {
                    matched += 1
                    if matched == detachSeq.count { requestDetach(); break loop }
                    continue
                } else if matched > 0 {
                    matched = 0
                }

                if byte == prefix {
                    awaitingPrefixCommand = true
                    matched = 1 // prefix could still start the detach seq
                    continue
                }

                forward.append(byte)
            }

            if !forward.isEmpty, let active = activeSurface {
                _ = try? client.request(.sendData(surfaceID: active, data: forward), timeout: 1)
            }
        }
    }

    /// Handle the byte after the prefix. Returns true if it was consumed as a
    /// command. Pane navigation is local to the compositor (which pane gets
    /// keystrokes + shows the cursor).
    private func handlePrefixCommand(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "o"): // next pane
            renderQueue.async { [weak self] in self?.cycleActive(+1) }
            return true
        case UInt8(ascii: ";"): // previous pane
            renderQueue.async { [weak self] in self?.cycleActive(-1) }
            return true
        case UInt8(ascii: "d"): // detach (also matched by detachSeq, belt & suspenders)
            requestDetach()
            return true
        default:
            return false
        }
    }

    private func cycleActive(_ delta: Int) {
        guard !rects.isEmpty else { return }
        let ids = rects.map { $0.surfaceID.uuidString }
        let cur = activeSurface.flatMap { ids.firstIndex(of: $0) } ?? 0
        let next = ((cur + delta) % ids.count + ids.count) % ids.count
        activeSurface = ids[next]
        compositor.invalidate()
        composeAndWrite()
    }

    // MARK: Structure changes

    private func installStructurePoll() {
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkStructure() }
        timer.resume()
        pollTimer = timer
    }

    private func scheduleStructureCheck() {
        renderQueue.async { [weak self] in self?.checkStructure() }
    }

    /// Re-fetch the tab; if its split tree changed, rebuild the layout. Runs on
    /// `renderQueue`.
    private func checkStructure() {
        guard case let .snapshot(snapshot)? = try? client.request(.getSnapshot, timeout: 1) else { return }
        guard let latest = WindowAttachClient.resolveTabByID(snapshot, id: tab.id) else {
            // Tab is gone — detach.
            requestDetach()
            return
        }
        if latest.rootPane != tab.rootPane || latest.zoomedPaneID != tab.zoomedPaneID || latest.title != tab.title {
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
        pollTimer?.cancel()
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
}
