import AppKit
import Foundation
import HarnessCore

@MainActor
public protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidChangeTitle(_ title: String, surfaceID: SurfaceID)
    func terminalHostDidChangeWorkingDirectory(_ path: String, surfaceID: SurfaceID)
    func terminalHostDidChangeFocus(_ focused: Bool, surfaceID: SurfaceID)
    func terminalHostDidRingBell(surfaceID: SurfaceID)
    func terminalHostDidRequestDesktopNotification(title: String, body: String, surfaceID: SurfaceID)
    func terminalHostDidClose(surfaceID: SurfaceID)
}

/// Hosts one terminal pane: Harness's native `HarnessTerminalSurfaceView` (GPU renderer +
/// engine) wired to the daemon-owned PTY. Input/resize go to the daemon; output is streamed
/// back and fed to the surface. The pane border/ring/mark overlays are drawn here.
@MainActor
public final class TerminalHostView: NSView {
    public let surfaceID: SurfaceID
    public weak var hostDelegate: TerminalHostDelegate?

    private let nativeView: HarnessTerminalSurfaceView
    private let daemonClient = DaemonClient()
    private let io: SurfaceIO
    private let inputGate: InputGate
    private var outputSubscription: DaemonSubscription?
    private var isWaiting = false
    private var isActiveBorder = false
    private var cachedSettings: HarnessSettings?
    private var cachedThemeName: String
    /// Spawn parameters, kept so the surface can be re-ensured on reconnect after a daemon restart
    /// (the respawned daemon recreates it from layout.json, but we re-send these in case it must).
    private let cachedCwd: String?
    private let cachedShell: String
    /// True while the pane is intentionally released (`detachFromDaemonSurface`) so the output
    /// stream ending does NOT trigger an auto-reconnect — the user/coordinator asked for the detach.
    private var intentionallyDetached = false
    /// Backoff counter for `scheduleDaemonReconnect`, reset to 0 on a successful (re)connect.
    private var reconnectAttempts = 0
    /// Off-main probe queue for reconnect so a still-restarting daemon never blocks the main thread.
    private let reconnectQueue = DispatchQueue(label: "com.robert.harness.reconnect")
    /// Theme-derived indicator colors. This package can't reach the app's palette,
    /// so the app pushes them via `applyBorderColors`. Default until the first push.
    public var activeBorderColor: NSColor = .systemBlue
    public var waitingRingColor: NSColor = .systemBlue

    static let terminalOverlayCornerRadius: CGFloat = 10

    public var showsWaitingRing: Bool {
        get { isWaiting }
        set {
            isWaiting = newValue
            borderOverlayView.needsDisplay = true
        }
    }

    public var showsActiveBorder: Bool {
        get { isActiveBorder }
        set {
            let changed = newValue != isActiveBorder
            isActiveBorder = newValue
            borderOverlayView.needsDisplay = true
            // `window-style`/`pane-style` dims inactive panes — re-resolve the base color
            // when focus changes (only worth a re-apply when a style is actually set).
            if changed, !paneStyles.isEmpty { applyNativeAppearance() }
            // Re-tint the pane-border label (active = focus accent) on focus change.
            if changed, !borderLabelField.isHidden { refreshBorderLabelStyle(text: borderLabelField.stringValue) }
        }
    }

    /// `window-style`/`pane-style` base colors (dim inactive panes). The active pane uses the
    /// `*-active-style` base; others the general one. Empty = no override.
    private var paneStyles = PaneStyleSet()

    /// Push the resolved pane-style options (from the app's `OptionStore`). Re-applies the
    /// appearance so a `set-option -g window-style …` takes effect on the next refresh.
    public func applyPaneStyles(_ styles: PaneStyleSet) {
        guard styles != paneStyles else { return }
        paneStyles = styles
        applyNativeAppearance()
    }

    /// `pane-border-format` label, overlaid on the top/bottom edge above the terminal. The GUI
    /// overlays it (the surface keeps full size) rather than reserving a row like the grid
    /// compositor — surface-appropriate, same shared format/options underneath.
    private let borderOverlayView = TerminalFrameOverlayView()
    private let borderLabelField = NSTextField(labelWithString: "")
    private var borderLabelTop: NSLayoutConstraint?
    private var borderLabelBottom: NSLayoutConstraint?

    /// Shown over the pane while it is detached from the daemon (output subscription dropped):
    /// a dimmed "released — click to re-grab" affordance. nil while attached.
    private var detachedOverlay: DetachedPaneOverlay?
    /// True while the user has explicitly released this pane (overlay visible) — distinct from a
    /// transient "not yet subscribed" state. Drives menu-item enablement.
    public var isDetachedFromDaemon: Bool { detachedOverlay != nil }

    /// Show a `pane-border-format` label at the top (or bottom) edge, or hide it (nil/empty).
    public func setPaneBorderLabel(_ text: String?, atTop: Bool) {
        let trimmed = text?.trimmingCharacters(in: .whitespaces)
        guard let trimmed, !trimmed.isEmpty else {
            borderLabelField.isHidden = true
            return
        }
        borderLabelField.isHidden = false
        borderLabelTop?.isActive = atTop
        borderLabelBottom?.isActive = !atTop
        refreshBorderLabelStyle(text: trimmed)
    }

    /// Active pane → the focus accent (brighter); inactive → a quiet secondary label, with a
    /// translucent backing so it reads over terminal content.
    private func refreshBorderLabelStyle(text: String) {
        borderLabelField.stringValue = text
        borderLabelField.textColor = isActiveBorder ? activeBorderColor : .secondaryLabelColor
        borderLabelField.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.7).cgColor
    }

    private var isMarked = false
    /// The "marked" pane (`select-pane -m`) — the implicit source for `join-pane`.
    /// Drawn as a distinct dashed accent border so the user can see the mark.
    public var showsMarkedBorder: Bool {
        get { isMarked }
        set {
            isMarked = newValue
            borderOverlayView.needsDisplay = true
        }
    }

    public init(
        surfaceID: SurfaceID = UUID(),
        workingDirectory: String? = nil,
        harnessSurfaceEnv: String? = nil,
        settings: HarnessSettings? = nil,
        themeName: String = ThemeManager.defaultThemeName
    ) {
        self.surfaceID = surfaceID
        self.cachedThemeName = themeName
        self.cachedSettings = settings
        let shell = settings?.defaultShell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.cachedShell = shell
        self.cachedCwd = workingDirectory
        let surfaceEnv = harnessSurfaceEnv ?? surfaceID.uuidString
        let io = SurfaceIO(surfaceID: surfaceEnv)
        self.io = io
        let inputGate = InputGate(io: io)
        self.inputGate = inputGate
        let nativeView = HarnessTerminalSurfaceView(
            themeName: themeName,
            fontFamily: settings?.fontFamily ?? "Menlo",
            fontSize: CGFloat(settings?.fontSize ?? 14),
            vivid: settings?.vividColors ?? false,
            colorRendering: settings?.colorRendering,
            colorGamut: settings?.colorGamut ?? .auto,
            offMainParserFramePipeline: settings?.offMainParserFramePipeline ?? true
        )
        self.nativeView = nativeView
        super.init(frame: .zero)
        ensureDaemonSurface(cwd: workingDirectory, shell: shell, settings: settings)
        configureNative(nativeView, io: io, inputGate: inputGate)
        startDaemonOutput()
        // If the very first subscribe didn't take (daemon mid-restart at creation), don't leave the
        // pane dead — retry on the same backoff that recovers a later drop.
        if outputSubscription == nil { scheduleDaemonReconnect() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Mount the surface filling the host and wire its input/resize to the PTY plumbing,
    /// plus title/cwd/bell/copy out to the delegate / paste buffer.
    private func configureNative(_ native: HarnessTerminalSurfaceView, io: SurfaceIO, inputGate: InputGate) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        native.translatesAutoresizingMaskIntoConstraints = false
        native.onInput = { data in inputGate.route(data) }
        native.onResize = { cols, rows in io.resize(rows: UInt16(rows), cols: UInt16(cols)) }
        native.onTitle = { [weak self] title in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidChangeTitle(title, surfaceID: self.surfaceID)
        }
        native.onPwd = { [weak self] path in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidChangeWorkingDirectory(path, surfaceID: self.surfaceID)
        }
        native.onBell = { [weak self] in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidRingBell(surfaceID: self.surfaceID)
        }
        native.onDesktopNotification = { [weak self] title, body in
            guard let self else { return }
            // OSC 9 carries no title; fall back to the app name so the banner reads sensibly.
            self.hostDelegate?.terminalHostDidRequestDesktopNotification(
                title: title ?? "Harness", body: body, surfaceID: self.surfaceID)
        }
        native.onCopy = { [weak self] text in
            self?.storeCopyBuffer(text)
        }
        addSubview(native)
        NSLayoutConstraint.activate([
            native.topAnchor.constraint(equalTo: topAnchor),
            native.leadingAnchor.constraint(equalTo: leadingAnchor),
            native.trailingAnchor.constraint(equalTo: trailingAnchor),
            native.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        borderOverlayView.translatesAutoresizingMaskIntoConstraints = false
        borderOverlayView.host = self
        addSubview(borderOverlayView)
        NSLayoutConstraint.activate([
            borderOverlayView.topAnchor.constraint(equalTo: topAnchor),
            borderOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            borderOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            borderOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // pane-border-format label overlay — added AFTER `native`/border so it sits above the
        // Metal surface and frame.
        borderLabelField.translatesAutoresizingMaskIntoConstraints = false
        borderLabelField.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        borderLabelField.alignment = .center
        borderLabelField.lineBreakMode = .byTruncatingTail
        borderLabelField.wantsLayer = true
        borderLabelField.layer?.cornerRadius = 3
        borderLabelField.isHidden = true
        addSubview(borderLabelField)
        let top = borderLabelField.topAnchor.constraint(equalTo: topAnchor, constant: 1)
        let bottom = borderLabelField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1)
        borderLabelTop = top
        borderLabelBottom = bottom
        NSLayoutConstraint.activate([
            borderLabelField.centerXAnchor.constraint(equalTo: centerXAnchor),
            borderLabelField.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8),
            top,
        ])
        applyNativeAppearance()
    }

    /// Push the full appearance to the surface, computed from the cached settings + theme.
    /// The canvas (default bg/fg/cursor) resolves through the SAME `ThemeManager.resolvedCanvas`
    /// the chrome uses, so terminal and chrome never seam. Program output keeps untouched/
    /// default ANSI colors unless `applyThemeToTerminalOutput` is on. The canvas is translucent
    /// when `backgroundOpacity` < 1 (window blur shows through); glyphs + explicit program
    /// backgrounds stay opaque.
    private func applyNativeAppearance() {
        guard let settings = cachedSettings else { return }
        let canvas = ThemeManager.resolvedCanvas(
            themeName: cachedThemeName,
            customBackgroundHex: settings.customBackgroundHex,
            customForegroundHex: settings.customForegroundHex,
            customCursorHex: settings.customCursorHex
        )
        // `window-style`/`pane-style`: a parsed base color overrides the canvas default for
        // this pane's default-colored cells (so an inactive pane dims). `.none` channels keep
        // the theme canvas. The active pane uses the `*-active-style` base.
        let styleBase = paneStyles.base(active: isActiveBorder)
        let canvasBg = Self.hexString(styleBase.bg) ?? canvas.backgroundHex
        let canvasFg = Self.hexString(styleBase.fg) ?? canvas.foregroundHex
        nativeView.configureAppearance(
            fontFamily: settings.fontFamily,
            fontSize: CGFloat(settings.fontSize),
            vivid: settings.vividColors,
            colorRendering: settings.colorRendering,
            colorGamut: settings.colorGamut,
            canvasBackgroundHex: canvasBg,
            canvasForegroundHex: canvasFg,
            cursorHex: canvas.cursorHex,
            outputPaletteHex: nativeOutputPaletteHex(settings: settings),
            canvasOpacity: HarnessSettings.clampedOpacity(settings.backgroundOpacity),
            cursorStyle: settings.cursorStyle,
            cursorBlink: settings.cursorBlink,
            paddingX: CGFloat(settings.windowPaddingX),
            paddingY: CGFloat(settings.windowPaddingY),
            selectionBackgroundHex: settings.selectionBackgroundHex
                ?? ThemeManager.selectionBackgroundHex(themeName: cachedThemeName),
            selectionForegroundHex: settings.selectionForegroundHex
                ?? ThemeManager.selectionForegroundHex(themeName: cachedThemeName),
            copyOnSelect: settings.copyOnSelect,
            scrollbackLines: settings.scrollbackLines,
            linearBlending: settings.linearBlending,
            textRendering: settings.textRendering,
            ligatures: settings.ligatures,
            promptGutter: settings.showPromptGutter,
            offMainParserFramePipeline: settings.offMainParserFramePipeline
        )
    }

    /// A parsed `window-style`/`pane-style` color as `#rrggbb` (xterm-256 resolved), or nil
    /// for `.none`/unset so the caller keeps the theme canvas color.
    private static func hexString(_ color: FormatColor?) -> String? {
        guard let rgb = color?.rgbComponents() else { return nil }
        return String(format: "#%02X%02X%02X", rgb.r, rgb.g, rgb.b)
    }

    /// Mirror a copy into the daemon paste buffer (parity with copy-mode), so `paste-buffer`
    /// and the buffer list see selections made by mouse.
    private func storeCopyBuffer(_ text: String) {
        guard !text.isEmpty else { return }
        let data = Data(text.utf8)
        DispatchQueue.global(qos: .utility).async {
            _ = try? DaemonClient().request(.setBuffer(name: nil, data: data))
        }
    }

    /// The 16 ANSI colors used for terminal *output*. When `applyThemeToTerminalOutput` is on,
    /// the theme's palette (seeded into settings, with theme fallback) recolors output;
    /// otherwise nil slots let the surface fall back to its untouched default palette so
    /// programs render their true colors.
    private func nativeOutputPaletteHex(settings: HarnessSettings) -> [String?] {
        guard settings.applyThemeToTerminalOutput else {
            return Array(repeating: nil, count: 16)
        }
        let themePalette = ThemeManager.paletteHex(themeName: cachedThemeName)
        return (0 ..< 16).map { settings.paletteHex[$0] ?? themePalette[$0] }
    }

    public func applyTheme(named name: String) {
        cachedThemeName = name
        applyNativeAppearance()
    }

    public func applySettings(_ settings: HarnessSettings) {
        cachedSettings = settings
        applyNativeAppearance()
    }

    /// Honor tmux `set-clipboard`: when false, programs cannot set the system
    /// clipboard via OSC 52. Default on (tmux's default); the app sets it from the
    /// daemon option.
    public var allowProgramClipboardAccess: Bool {
        get { nativeView.allowProgramClipboardAccess }
        set { nativeView.allowProgramClipboardAccess = newValue }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window?.firstResponder !== nativeView {
            window?.makeFirstResponder(nativeView)
        }
    }

    fileprivate func drawTerminalOverlay(in bounds: NSRect) {
        // The waiting ring (urgent) takes precedence over the quieter active-pane
        // border so a pane that needs attention never reads as merely focused.
        if isWaiting {
            // Two-stroke ring: a soft outer halo + a crisp inner stroke. Reads as
            // "needs attention" without screaming.
            strokeIndicator(in: bounds, color: waitingRingColor, lineWidth: 4, alpha: 0.18, inset: 1)
            strokeIndicator(in: bounds, color: waitingRingColor, lineWidth: 1.5, alpha: 0.85, inset: 2)
        } else if isActiveBorder {
            // Minimal focused-pane hairline — only ever drawn when a tab is split
            // (gated in SessionCoordinator.setActiveSurface). A lone terminal keeps only
            // the neutral frame; split focus adds this subtle edge light.
            strokeIndicator(in: bounds, color: activeBorderColor, lineWidth: 1, alpha: 0.42, inset: 1)
        }
        // The marked pane (join-pane source) gets a distinct dashed accent on top,
        // so it reads as "marked" independently of focus.
        if isMarked {
            let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath(
                roundedRect: rect,
                xRadius: Self.terminalOverlayCornerRadius,
                yRadius: Self.terminalOverlayCornerRadius
            )
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            waitingRingColor.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }

    private func strokeIndicator(
        in bounds: NSRect,
        color: NSColor,
        lineWidth: CGFloat,
        alpha: CGFloat,
        inset: CGFloat? = nil
    ) {
        let effectiveInset = inset ?? lineWidth
        let rect = bounds.insetBy(dx: effectiveInset, dy: effectiveInset)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Self.terminalOverlayCornerRadius,
            yRadius: Self.terminalOverlayCornerRadius
        )
        color.withAlphaComponent(alpha).setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    /// Push theme-derived indicator colors from the app's palette.
    public func applyBorderColors(active: NSColor, waiting: NSColor) {
        activeBorderColor = active
        waitingRingColor = waiting
        borderOverlayView.needsDisplay = true
    }

    public func focusTerminal() {
        window?.makeFirstResponder(nativeView)
        hostDelegate?.terminalHostDidChangeFocus(true, surfaceID: surfaceID)
    }

    // MARK: - Find (Cmd+F)

    private var findBar: TerminalFindBar?

    /// Toggle the in-pane find bar. Opening focuses its field (keystrokes go to the bar, not
    /// the shell); closing clears highlights and returns focus to the terminal.
    public func toggleFind() {
        if findBar != nil { hideFind() } else { showFind() }
    }

    private func showFind() {
        guard findBar == nil else { findBar?.focusField(); return }
        let bar = TerminalFindBar()
        bar.onQueryChanged = { [weak self] query in self?.nativeView.updateFind(query: query) }
        bar.onNext = { [weak self] in self?.nativeView.findNext() }
        bar.onPrevious = { [weak self] in self?.nativeView.findPrevious() }
        bar.onClose = { [weak self] in self?.hideFind() }
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        nativeView.onFindResultsChanged = { [weak bar] current, total in bar?.setResults(current: current, total: total) }
        nativeView.beginFind()
        findBar = bar
        bar.focusField()
    }

    private func hideFind() {
        guard let bar = findBar else { return }
        nativeView.onFindResultsChanged = nil
        nativeView.endFind()
        bar.removeFromSuperview()
        findBar = nil
        focusTerminal()
    }

    // MARK: - Copy mode (in-pane overlay)

    public var isInCopyMode: Bool { nativeView.isInCopyMode }

    /// Enter copy mode on this pane's native surface, using the `mode-keys` table.
    public func enterCopyMode(modeKeys: String) {
        nativeView.copyModeKeys = modeKeys
        nativeView.enterCopyMode()
        window?.makeFirstResponder(nativeView)
    }

    public func exitCopyMode() { nativeView.exitCopyMode() }

    /// Run a `copy-mode -X` action (from the `:` prompt / `send-keys -X`); no-op if inactive.
    public func performCopyModeAction(_ action: CopyModeAction) {
        nativeView.performCopyModeAction(action)
    }

    /// Release this pane to headless: cancel the daemon output subscription, which drops this
    /// client's hold (subscription + size vote) on the surface while the PTY keeps running. The
    /// session stays alive for `reattachToDaemonSurface()` (or another client) to re-grab.
    public func detachFromDaemonSurface() {
        guard outputSubscription != nil else { return }   // already detached — keep one overlay
        intentionallyDetached = true // suppress auto-reconnect: this detach is deliberate
        outputSubscription?.cancel()
        outputSubscription = nil
        io.attach(subscription: nil) // fall back to the per-call client while detached
        showDetachedOverlay()
    }

    /// Re-grab a surface released with `detachFromDaemonSurface()`: resubscribe and replay
    /// scrollback so the pane catches up. No-op if still attached.
    public func reattachToDaemonSurface() {
        guard outputSubscription == nil else { return }
        intentionallyDetached = false
        reconnectAttempts = 0
        hideDetachedOverlay()
        startDaemonOutput(resetBeforeReplay: true)
    }

    /// Drop a dimmed "released — click to re-grab" affordance over the frozen pane. Topmost so it
    /// captures the click; re-grabbing tears it down. Idempotent.
    private func showDetachedOverlay() {
        guard detachedOverlay == nil else { return }
        let overlay = DetachedPaneOverlay(frame: bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.onReattach = { [weak self] in self?.reattachToDaemonSurface() }
        addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        detachedOverlay = overlay
    }

    private func hideDetachedOverlay() {
        detachedOverlay?.removeFromSuperview()
        detachedOverlay = nil
    }

    /// Scroll the viewport to the previous/next OSC 133 shell prompt (no-op without shell
    /// integration marks).
    public func jumpToPreviousPrompt() { nativeView.jumpToPreviousPrompt() }
    public func jumpToNextPrompt() { nativeView.jumpToNextPrompt() }

    /// `synchronize-panes`: the surface-id strings (excluding this pane) that this
    /// pane's input should also be mirrored to. Empty = normal single-pane input.
    public func setSyncSiblings(_ surfaceIDStrings: [String]) {
        inputGate.setSiblings(surfaceIDStrings)
    }

    /// Returns true iff the daemon acknowledged the surface (`.ok`). Reconnect gates resubscribe on
    /// this so it never subscribes to a surface the (still-restarting) daemon hasn't recreated yet.
    @discardableResult
    private func ensureDaemonSurface(cwd: String?, shell: String, settings: HarnessSettings?) -> Bool {
        do {
            if case .ok = try daemonClient.request(.ensureSurface(
                surfaceID: surfaceID.uuidString,
                cwd: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
                shell: shell,
                rows: 24,
                cols: 80,
                scrollbackBytes: (settings?.scrollbackLines ?? 10_000) * 160
            )) {
                return true
            }
        } catch {
            fputs("Harness: ensureSurface failed for \(surfaceID.uuidString): \(error)\n", stderr)
        }
        return false
    }

    private func startDaemonOutput(resetBeforeReplay: Bool = false) {
        // Reconnect/reattach: reset the emulator (RIS) first so the replayed scrollback replaces
        // stale pre-restart content instead of stacking on it (which shows a doubled prompt). On the
        // first connect the emulator is empty, so RIS would be a no-op — keep it off that path.
        if resetBeforeReplay {
            nativeView.receive("\u{1b}c")
        }
        do {
            if case let .text(text) = try daemonClient.request(.replayScrollback(
                surfaceID: surfaceID.uuidString,
                fromSequence: nil
            )), !text.isEmpty {
                nativeView.receive(text)
            }
        } catch {
            fputs("Harness: replayScrollback failed for \(surfaceID.uuidString): \(error)\n", stderr)
        }
        do {
            outputSubscription = try daemonClient.subscribeSurfaceOutput(
                surfaceID: surfaceID.uuidString,
                label: "Harness.app",
                onData: makeOutputDataHandler(),
                onEnd: makeOutputEndHandler()
            )
            // Ride this persistent full-duplex connection for input (fire-and-forget), replacing
            // the per-keystroke socket connect + blocking round trip. `attach` also re-asserts the
            // last grid size, so a surface respawned at the daemon's placeholder size is corrected.
            io.attach(subscription: outputSubscription)
        } catch {
            fputs("Harness: output subscription failed for \(surfaceID.uuidString): \(error)\n", stderr)
        }
    }

    /// Output-stream data handler, shared by the initial connect and the off-main reconnect. Feeds
    /// the emulator on the main thread IN ORDER: the subscription read loop is serial (frames decode
    /// in the daemon's byte order) and `DispatchQueue.main.async` is strict FIFO, so byte order is
    /// preserved end to end. An unstructured `Task { @MainActor in }` is NOT order-preserving — under
    /// fast/bursty output (the binary transport makes decode far faster, so chunks arrive
    /// back-to-back) two tasks could run on the main actor out of order, feeding a TUI's
    /// cursor-positioned redraws to the emulator scrambled (overlapping, interleaved text).
    private func makeOutputDataHandler() -> @Sendable (Data, UInt64) -> Void {
        { [weak self] data, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.nativeView.receive(data) }
            }
        }
    }

    /// Output-stream end handler, shared by the initial connect and the off-main reconnect. If we
    /// didn't ask for the stream to end (the daemon restarted/crashed and launchd respawned it — or,
    /// in dev, a newer build replaced it on launch), the pane would otherwise be stuck on a dead
    /// socket: no output, and input writing to a dead fd. Drop to the per-call input fallback
    /// immediately, then reconnect.
    private func makeOutputEndHandler() -> @Sendable () -> Void {
        { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.outputSubscription = nil
                    self.io.attach(subscription: nil)
                    if !self.intentionallyDetached { self.scheduleDaemonReconnect() }
                }
            }
        }
    }

    /// Recover a surface whose output stream dropped unexpectedly (daemon restart/crash). Probe the
    /// daemon off-main so a still-restarting one never blocks the UI; once it answers, re-ensure the
    /// surface (idempotent — the respawned daemon already recreated it from layout.json) and
    /// resubscribe with a clean replay. Bounded backoff covers the restart window; after that, fall
    /// back to the manual "click to re-grab" affordance. No-op once intentionally detached.
    private func scheduleDaemonReconnect() {
        guard !intentionallyDetached, outputSubscription == nil else { return }
        guard reconnectAttempts < 60 else {
            showDetachedOverlay() // ~50s of retries elapsed; let the user re-grab manually
            return
        }
        let attempt = reconnectAttempts
        reconnectAttempts += 1
        let delay = min(0.1 * Double(attempt + 1), 1.0)
        // Capture main-actor state so the whole probe + (re)attach handshake — ping, ensureSurface,
        // replayScrollback, and subscribe — runs OFF main. A still-restarting daemon answers slowly
        // (or its socket blocks), so doing these synchronous round trips on main froze the UI for the
        // duration of every retry. Only the view touches (RIS reset, replay receive, subscription
        // assignment, `io.attach`) hop back to main.
        let client = daemonClient
        let sid = surfaceID.uuidString
        let cwd = cachedCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let shell = cachedShell
        let scrollbackBytes = (cachedSettings?.scrollbackLines ?? 10_000) * 160
        let onData = makeOutputDataHandler()
        let onEnd = makeOutputEndHandler()
        // The view touches are built on main as `@Sendable` closures capturing `[weak self]`, so the
        // off-main worker never captures the (non-Sendable, @MainActor) `self` itself — it only calls
        // these to hop back. `onReplay`: reset stale content (RIS) + replay history; `onAttached`:
        // commit the new subscription (or, on nil, reschedule the backoff).
        let onReplay: @Sendable (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.intentionallyDetached, self.outputSubscription == nil else { return }
                    self.nativeView.receive("\u{1b}c")
                    if !text.isEmpty { self.nativeView.receive(text) }
                }
            }
        }
        let onAttached: @Sendable (DaemonSubscription?) -> Void = { [weak self] subscription in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.intentionallyDetached, self.outputSubscription == nil else {
                        subscription?.cancel() // raced an intentional detach / another attach — drop it
                        return
                    }
                    if let subscription {
                        self.outputSubscription = subscription
                        // Ride this persistent full-duplex connection for input; `attach` re-asserts
                        // the last grid size, correcting a surface respawned at the placeholder size.
                        self.io.attach(subscription: subscription)
                        self.reconnectAttempts = 0
                        self.hideDetachedOverlay()
                    } else {
                        self.scheduleDaemonReconnect() // daemon not back / subscribe failed — retry
                    }
                }
            }
        }
        reconnectQueue.asyncAfter(deadline: .now() + delay) {
            // Ping first: a still-restarting daemon answers nothing, so bail to a retry rather than
            // block. Then re-ensure the surface (idempotent — the respawned daemon already recreated
            // it from layout.json); subscribing while the surface is still missing would be rejected
            // and bounce straight back here.
            guard case .pong? = try? client.request(.ping, timeout: 0.5) else { onAttached(nil); return }
            guard case .ok? = try? client.request(.ensureSurface(
                surfaceID: sid, cwd: cwd, shell: shell, rows: 24, cols: 80, scrollbackBytes: scrollbackBytes
            )) else { onAttached(nil); return }
            var replayText = ""
            if case let .text(text)? = try? client.request(.replayScrollback(surfaceID: sid, fromSequence: nil)) {
                replayText = text
            }
            // Reset + replay on main BEFORE the live stream starts: this main hop is queued before the
            // subscribe below, and `onData` only ever hops to main AFTER the subscribe — so FIFO
            // guarantees the replayed history lands before any live byte.
            onReplay(replayText)
            let subscription = try? client.subscribeSurfaceOutput(
                surfaceID: sid, label: "Harness.app", onData: onData, onEnd: onEnd
            )
            onAttached(subscription)
        }
    }

    deinit {
        outputSubscription?.cancel()
    }
}

@MainActor
private final class TerminalFrameOverlayView: NSView {
    weak var host: TerminalHostView?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        host?.drawTerminalOverlay(in: bounds)
    }
}

/// A dimmed overlay shown over a pane that has been released from the daemon (`detach-client`):
/// the pane stops updating, and this banner makes the state visible and offers a one-click
/// re-grab. It captures mouse events so a click anywhere on the frozen pane re-attaches rather
/// than reaching the stale surface underneath.
@MainActor
private final class DetachedPaneOverlay: NSView {
    var onReattach: (() -> Void)?
    private let label = NSTextField(labelWithString: "Pane released — click to re-grab")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A click anywhere re-grabs the surface.
    override func mouseDown(with event: NSEvent) { onReattach?() }
    /// Re-grab even when the window isn't key (the first click also focuses).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Swallow scroll so the frozen pane underneath doesn't react to wheel events.
    override func scrollWheel(with event: NSEvent) {}
}

/// Serializes a surface's PTY input/resize onto one ordered background queue with a
/// single reused `DaemonClient`. A fresh client per write on the concurrent global
/// queue (the old approach) could reorder bytes to the PTY and allocated needlessly;
/// this keeps writes ordered and off the main thread.
/// @unchecked Sendable: `DaemonClient` is itself thread-safe and `surfaceID` is immutable.
private final class SurfaceIO: @unchecked Sendable {
    private let client = DaemonClient()
    private let queue = DispatchQueue(label: "com.robert.harness.terminal-io")
    private let surfaceID: String
    private let lock = NSLock()
    /// The live full-duplex output subscription, once `startDaemonOutput` wires it. Input rides this
    /// connection (`sendInput`, fire-and-forget) instead of the per-keystroke connect + blocking
    /// `.ok` round trip of `DaemonClient.request(.sendData:)`. Guarded by `lock` (set on main during
    /// (re)attach, read on `queue`).
    private var subscription: DaemonSubscription?
    /// Last grid size sent, re-asserted on (re)attach so a surface a restarted daemon respawned at
    /// its placeholder size is corrected without waiting for the next layout pass. Guarded by `lock`.
    private var lastRows: UInt16 = 0
    private var lastCols: UInt16 = 0

    init(surfaceID: String) { self.surfaceID = surfaceID }

    /// Point input at the live subscription (or `nil` to fall back to the per-call client, e.g. when
    /// the pane is detached). Covers both first attach and re-grab.
    func attach(subscription: DaemonSubscription?) {
        lock.lock()
        self.subscription = subscription
        let rows = lastRows, cols = lastCols
        lock.unlock()
        // Re-assert the grid size on attach: a surface respawned by a restarted daemon comes up at
        // the daemon's placeholder size until a client resize vote arrives.
        if subscription != nil, rows > 0, cols > 0 {
            queue.async { [client, surfaceID] in
                _ = try? client.request(.resizeSurface(surfaceID: surfaceID, rows: rows, cols: cols))
            }
        }
    }

    private var currentSubscription: DaemonSubscription? {
        lock.lock(); defer { lock.unlock() }; return subscription
    }

    func send(_ data: Data) {
        // Stay on `queue` so keystrokes are ordered and off the main thread (matching the old
        // path); the write itself is now one frame on the persistent fd with no socket setup or
        // reply wait. Before the subscription exists (first keystrokes), fall back to the client.
        queue.async { [weak self, client, surfaceID] in
            if let sub = self?.currentSubscription {
                sub.sendInput(data, surfaceID: surfaceID)
            } else {
                _ = try? client.request(.sendData(surfaceID: surfaceID, data: data))
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        lock.lock(); lastRows = rows; lastCols = cols; lock.unlock()
        queue.async { [client, surfaceID] in
            _ = try? client.request(.resizeSurface(surfaceID: surfaceID, rows: rows, cols: cols))
        }
    }
}

/// Routes a pane's keyboard input. Normally just forwards to the pane's own PTY.
/// When `synchronize-panes` is on, the app sets sibling surface ids and each
/// keystroke is also mirrored to them via the daemon (so typing hits every pane
/// in the window). Fully sendable — holds only strings + a thread-safe client,
/// never a view — so it's safe to call from any input callback thread.
private final class InputGate: @unchecked Sendable {
    private let io: SurfaceIO
    private let broadcastClient = DaemonClient()
    private let broadcastQueue = DispatchQueue(label: "com.robert.harness.sync-input")
    private let lock = NSLock()
    private var siblingsStorage: [String] = []

    init(io: SurfaceIO) { self.io = io }

    func setSiblings(_ ids: [String]) {
        lock.lock(); siblingsStorage = ids; lock.unlock()
    }

    private var siblings: [String] {
        lock.lock(); defer { lock.unlock() }; return siblingsStorage
    }

    func route(_ data: Data) {
        io.send(data)
        let mirrors = siblings
        guard !mirrors.isEmpty else { return }
        broadcastQueue.async { [broadcastClient] in
            for sid in mirrors {
                _ = try? broadcastClient.request(.sendData(surfaceID: sid, data: data))
            }
        }
    }
}
