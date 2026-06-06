import AppKit
import Foundation
import HarnessCore
import HarnessTerminalEngine
import HarnessTheme

@MainActor
public protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidChangeTitle(_ title: String, surfaceID: SurfaceID)
    func terminalHostDidChangeWorkingDirectory(_ path: String, surfaceID: SurfaceID)
    func terminalHostDidChangeFocus(_ focused: Bool, surfaceID: SurfaceID)
    func terminalHostDidRingBell(surfaceID: SurfaceID)
    /// A shell command finished (OSC 133) after running `duration` seconds, with `exitCode`.
    func terminalHostDidFinishCommand(duration: TimeInterval, exitCode: Int?, surfaceID: SurfaceID)
    func terminalHostDidRequestDesktopNotification(title: String, body: String, surfaceID: SurfaceID)
    /// ConEmu progress report (OSC 9;4) from the program in this pane — drives the tab's
    /// working indicator (Claude Code 2.0+ keep-alives one across each turn).
    func terminalHostDidUpdateProgress(_ report: TerminalProgressReport, surfaceID: SurfaceID)
    func terminalHostDidClose(surfaceID: SurfaceID)
}

extension TerminalHostDelegate {
    /// Default no-op so non-GUI conformers (e.g. the compositor) need not handle command timing.
    public func terminalHostDidFinishCommand(duration: TimeInterval, exitCode: Int?, surfaceID: SurfaceID) {}
    /// Default no-op — only the GUI tab strip renders progress.
    public func terminalHostDidUpdateProgress(_ report: TerminalProgressReport, surfaceID: SurfaceID) {}
}

/// Hosts one terminal pane: Harness's native `HarnessTerminalSurfaceView` (GPU renderer +
/// engine) wired to the daemon-owned PTY. Input/resize go to the daemon; output is streamed
/// back and fed to the surface. The pane border/ring/mark overlays are drawn here.
@MainActor
public final class TerminalHostView: NSView {
    public let surfaceID: SurfaceID
    public weak var hostDelegate: TerminalHostDelegate?

    private let nativeView: HarnessTerminalSurfaceView
    /// Which daemon this pane talks to — the local one by default, or a remote daemon (via an SSH
    /// tunnel) when the pane belongs to a connected remote host.
    private let daemonClient: DaemonClient
    private let io: SurfaceIO
    private let inputGate: InputGate
    private var outputSubscription: DaemonSubscription?
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

    /// Live "120 × 32" resize overlay (Ghostty's resize-overlay). Floats above the surface; its
    /// position constraints are toggled from settings and it auto-hides on its own.
    private let resizeHUD = ResizeHUDView()
    private let scrollbar = TerminalScrollbarView()
    private var resizeHUDConstraints: [ResizeOverlayPosition: [NSLayoutConstraint]] = [:]
    private var resizeHUDPosition: ResizeOverlayPosition?
    /// The terminal's initial sizing isn't a resize — `after-first` skips the overlay for it.
    private var hasSeenInitialGridSize = false

    /// Shown over the pane while it is detached from the daemon (output subscription dropped):
    /// a dimmed "released — click to re-grab" affordance. nil while attached.
    private var detachedOverlay: DetachedPaneOverlay?
    /// True while the user has explicitly released this pane (overlay visible) — distinct from a
    /// transient "not yet subscribed" state. Drives menu-item enablement.
    public var isDetachedFromDaemon: Bool { detachedOverlay != nil }

    /// A small, non-interactive "Reconnecting…" status chip shown in the corner while the output
    /// stream is dropped and the backoff is retrying (daemon restart/crash). Distinct from
    /// `detachedOverlay` (the full-pane click-to-re-grab affordance that only appears after the
    /// backoff is exhausted): this is a quiet liveness cue during the ~55s recovery window so the
    /// pane isn't silently frozen. Hidden the moment the resubscribe succeeds. nil while attached.
    private var reconnectingOverlay: DetachedPaneOverlay?

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
        themeName: String = ThemeManager.defaultThemeName,
        endpoint: Endpoint = .localControlSocket
    ) {
        self.surfaceID = surfaceID
        self.daemonClient = DaemonClient(endpoint: endpoint)
        self.cachedThemeName = themeName
        self.cachedSettings = settings
        let shell = settings?.defaultShell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        self.cachedShell = shell
        self.cachedCwd = workingDirectory
        let surfaceEnv = harnessSurfaceEnv ?? surfaceID.uuidString
        let io = SurfaceIO(surfaceID: surfaceEnv, endpoint: endpoint)
        self.io = io
        let inputGate = InputGate(io: io, endpoint: endpoint)
        self.inputGate = inputGate
        let nativeView = HarnessTerminalSurfaceView(
            themeName: themeName,
            fontFamily: settings?.fontFamily ?? "Menlo",
            fontSize: CGFloat(settings?.fontSize ?? 14),
            vivid: settings?.vividColors ?? false,
            colorRendering: settings?.colorRendering,
            colorGamut: settings?.colorGamut ?? .auto,
            offMainParserFramePipeline: settings?.offMainParserFramePipeline ?? true,
            liveResizeReflow: settings?.liveResizeReflow ?? true
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
        native.onProgress = { [weak self] report in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidUpdateProgress(report, surfaceID: self.surfaceID)
        }
        native.onPwd = { [weak self] path in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidChangeWorkingDirectory(path, surfaceID: self.surfaceID)
        }
        native.onBell = { [weak self] in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidRingBell(surfaceID: self.surfaceID)
        }
        native.onCommandFinished = { [weak self] duration, exitCode in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidFinishCommand(
                duration: duration, exitCode: exitCode, surfaceID: self.surfaceID)
        }
        native.onDesktopNotification = { [weak self] title, body in
            guard let self else { return }
            // OSC 9 carries no title; fall back to the app name so the banner reads sensibly.
            self.hostDelegate?.terminalHostDidRequestDesktopNotification(
                title: title ?? "Harness", body: body, surfaceID: self.surfaceID)
        }
        native.onBecameFocused = { [weak self] in
            guard let self else { return }
            // Focusing a pane (click, ⌘-Tab back to the app, window key) clears its pending
            // notification — the same delegate path a programmatic tab switch already uses.
            self.hostDelegate?.terminalHostDidChangeFocus(true, surfaceID: self.surfaceID)
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

        // Resize dimensions overlay — added last so it floats above the surface, frame, and
        // border label. The active position constraint set is toggled in applyNativeAppearance.
        addSubview(resizeHUD)
        let hudInset: CGFloat = 12
        resizeHUDConstraints = [
            .center: [
                resizeHUD.centerXAnchor.constraint(equalTo: centerXAnchor),
                resizeHUD.centerYAnchor.constraint(equalTo: centerYAnchor),
            ],
            .topRight: [
                resizeHUD.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hudInset),
                resizeHUD.topAnchor.constraint(equalTo: topAnchor, constant: hudInset),
            ],
            .bottomRight: [
                resizeHUD.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hudInset),
                resizeHUD.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -hudInset),
            ],
        ]
        native.onGridSizeWillChange = { [weak self] cols, rows, _ in
            guard let self, let settings = self.cachedSettings else { return }
            let isInitial = !self.hasSeenInitialGridSize
            self.hasSeenInitialGridSize = true
            switch settings.resizeOverlay {
            case .never: return
            case .afterFirst where isInitial: return // opening a window isn't a resize
            default: break
            }
            guard !self.nativeView.isInCopyMode else { return }
            self.resizeHUD.show(cols: cols, rows: rows)
        }

        // Transient scrollbar — added last so the thumb floats above the surface and frame.
        // A thin strip pinned to the trailing edge, full height; flashes on scroll then fades.
        addSubview(scrollbar)
        NSLayoutConstraint.activate([
            scrollbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollbar.topAnchor.constraint(equalTo: topAnchor),
            scrollbar.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollbar.widthAnchor.constraint(equalToConstant: TerminalScrollbarView.stripWidth),
        ])
        native.onScrollChanged = { [weak self] topLine, totalLines, visibleRows in
            self?.scrollbar.show(topLine: topLine, totalLines: totalLines, visibleRows: visibleRows)
        }

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
            paddingBalance: settings.windowPaddingBalance,
            selectionBackgroundHex: settings.selectionBackgroundHex
                ?? ThemeManager.selectionBackgroundHex(themeName: cachedThemeName),
            selectionForegroundHex: settings.selectionForegroundHex
                ?? ThemeManager.selectionForegroundHex(themeName: cachedThemeName),
            cursorTextHex: settings.cursorTextHex
                ?? ThemeManager.cursorTextHex(themeName: cachedThemeName),
            copyOnSelect: settings.copyOnSelect,
            pasteProtection: settings.pasteProtection,
            scrollbackLines: settings.scrollbackLines,
            linearBlending: settings.linearBlending,
            textRendering: settings.textRendering,
            ligatures: settings.ligatures,
            minimumContrast: HarnessSettings.clampedContrast(settings.minimumContrast),
            boldIsBright: settings.boldIsBright,
            promptGutter: settings.showPromptGutter,
            offMainParserFramePipeline: settings.offMainParserFramePipeline,
            liveResizeReflow: settings.liveResizeReflow
        )
        // Resize overlay: legible on any theme via the canvas FG fill + BG text (same trick as the
        // pane-border label), positioned per settings.
        resizeHUD.applyColors(
            text: Self.nsColor(hex: canvasBg, fallback: .windowBackgroundColor),
            fill: Self.nsColor(hex: canvasFg, fallback: .labelColor)
        )
        scrollbar.applyColor(Self.nsColor(hex: canvasFg, fallback: .labelColor))
        applyResizeHUDPosition(settings.resizeOverlayPosition)
    }

    /// Activate only the constraint set for the configured overlay position.
    private func applyResizeHUDPosition(_ position: ResizeOverlayPosition) {
        guard position != resizeHUDPosition else { return }
        resizeHUDConstraints.values.forEach { NSLayoutConstraint.deactivate($0) }
        if let constraints = resizeHUDConstraints[position] { NSLayoutConstraint.activate(constraints) }
        resizeHUDPosition = position
    }

    private static func nsColor(hex: String, fallback: NSColor) -> NSColor {
        guard let c = RGBColor(hex: hex) else { return fallback }
        return NSColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255,
                       blue: CGFloat(c.blue) / 255, alpha: 1)
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
        let client = daemonClient // same daemon (local or remote) this pane is bound to
        DispatchQueue.global(qos: .utility).async {
            _ = try? client.request(.setBuffer(name: nil, data: data))
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

    /// Set the terminal identity the engine answers in XTVERSION / secondary DA. The app resolves
    /// this from the `terminal-identity` option (HarnessCore `TerminalIdentity`).
    public func setTerminalIdentity(name: String, version: String, daVersion: Int) {
        nativeView.setTerminalIdentity(name: name, version: version, daVersion: daVersion)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window?.firstResponder !== nativeView {
            window?.makeFirstResponder(nativeView)
        }
    }

    fileprivate func drawTerminalOverlay(in bounds: NSRect) {
        // Note: no pane border is drawn for focus or waiting state — both read as an
        // unwanted edge around the terminal. Waiting/attention surfaces via the tab
        // working dot, bell badge, and notifications; `showsActiveBorder` is kept for
        // its focus-change side effects only (pane-style dimming + border-label tint).
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
        hideReconnectingOverlay() // a deliberate release supersedes any in-flight reconnect cue
        showDetachedOverlay()
    }

    /// Re-grab a surface released with `detachFromDaemonSurface()`: resubscribe and replay
    /// scrollback so the pane catches up. No-op if still attached.
    public func reattachToDaemonSurface() {
        guard outputSubscription == nil else { return }
        intentionallyDetached = false
        reconnectAttempts = 0
        hideReconnectingOverlay()
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

    /// Drop a small, unobtrusive "Reconnecting…" chip in the top-right while the backoff retries.
    /// Non-interactive (passes clicks/scroll through to the frozen pane) and does not steal focus —
    /// it's a liveness cue, not the re-grab affordance. Idempotent; no-op if the full detached
    /// overlay is already up (the backoff was exhausted, so the chip would be redundant).
    private func showReconnectingOverlay() {
        guard reconnectingOverlay == nil, detachedOverlay == nil else { return }
        let overlay = DetachedPaneOverlay(frame: bounds, style: .reconnectingChip)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reconnectingOverlay = overlay
    }

    private func hideReconnectingOverlay() {
        reconnectingOverlay?.removeFromSuperview()
        reconnectingOverlay = nil
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
            fputs("Harness: ensureSurface failed for \(surfaceID.uuidString): \(error)\n", harnessStderr)
        }
        return false
    }

    private func startDaemonOutput(resetBeforeReplay: Bool = false) {
        // Gap-free attach: subscribe FIRST (live frames buffer), THEN replay, then flush the
        // buffered live frames deduped against the replay boundary — so a byte appended between the
        // replay snapshot and the handler registration is delivered exactly once instead of dropped.
        // `onReplay` resets stale content (when reconnecting) and feeds the replayed history; both
        // run on main, and live frames only reach main AFTER this (via `makeOutputDataHandler`'s
        // `main.async`), so FIFO keeps history before live output.
        let reset = resetBeforeReplay
        let onData = makeOutputDataHandler()
        let onReplay: @Sendable (String) -> Void = { [weak self] text in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Reconnect/reattach: RIS first so the replay replaces stale pre-restart content
                    // instead of stacking on it. First connect: emulator empty, so RIS is a no-op.
                    if reset { self.nativeView.receive("\u{1b}c") }
                    if !text.isEmpty { self.nativeView.receive(text) }
                }
            }
        }
        do {
            outputSubscription = try daemonClient.attachReplayingSurfaceOutput(
                surfaceID: surfaceID.uuidString,
                label: "Harness.app",
                onReplay: onReplay,
                onData: onData,
                onEnd: makeOutputEndHandler()
            )
            // Ride this persistent full-duplex connection for input (fire-and-forget), replacing
            // the per-keystroke socket connect + blocking round trip. `attach` also re-asserts the
            // last grid size, so a surface respawned at the daemon's placeholder size is corrected.
            io.attach(subscription: outputSubscription)
        } catch {
            fputs("Harness: output subscription failed for \(surfaceID.uuidString): \(error)\n", harnessStderr)
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
            hideReconnectingOverlay() // the chip gives way to the full re-grab affordance
            showDetachedOverlay() // ~50s of retries elapsed; let the user re-grab manually
            return
        }
        // Surface a quiet "Reconnecting…" cue at the start of the backoff so a dropped stream isn't
        // silently frozen for the whole recovery window. Hidden on a successful re-attach (or when
        // the backoff is exhausted and the full re-grab overlay takes over). Idempotent.
        showReconnectingOverlay()
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
                        self.hideReconnectingOverlay()
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
            // Gap-free resubscribe: the helper subscribes first (buffering live frames), replays,
            // then flushes the buffered frames deduped against the replay boundary — closing the
            // window where a byte appended between the replay and the subscribe was dropped. The
            // helper invokes `onReplay` (reset + replayed history on main) before the live stream,
            // and the buffered/live frames reach main via `onData` AFTER it, so FIFO keeps order.
            let subscription = try? client.attachReplayingSurfaceOutput(
                surfaceID: sid, label: "Harness.app", onReplay: onReplay, onData: onData, onEnd: onEnd
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
    /// `detached` = the full-pane dim + centered "click to re-grab" affordance (captures clicks).
    /// `reconnectingChip` = a small, corner-pinned, non-interactive "Reconnecting…" liveness cue
    /// shown during the backoff window (passes events through, shares the same chrome palette).
    enum Style { case detached, reconnectingChip }

    var onReattach: (() -> Void)?
    private let style: Style
    private let label: NSTextField

    init(frame frameRect: NSRect, style: Style = .detached) {
        self.style = style
        self.label = NSTextField(labelWithString: style == .detached ? "Pane released — click to re-grab" : "Reconnecting…")
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false

        switch style {
        case .detached:
            // Dim the whole pane and center the affordance.
            layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
            ])
        case .reconnectingChip:
            // A small rounded chip pinned top-right; the overlay itself stays transparent so the
            // pane underneath shows through. Reuses the detached overlay's dark/white palette.
            let chip = NSView()
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            chip.layer?.cornerRadius = 6
            chip.addSubview(label)
            addSubview(chip)
            NSLayoutConstraint.activate([
                chip.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                chip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -10),
                label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -4),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The reconnecting chip is a passive cue — let every event fall through to the pane underneath
    /// so the user can still scroll/select the frozen content. The detached overlay captures.
    override func hitTest(_ point: NSPoint) -> NSView? {
        style == .reconnectingChip ? nil : super.hitTest(point)
    }

    /// A click anywhere re-grabs the surface (detached style only; the chip never hit-tests).
    override func mouseDown(with event: NSEvent) { onReattach?() }
    /// Re-grab even when the window isn't key (the first click also focuses).
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { style == .detached }
    /// Swallow scroll so the frozen pane underneath doesn't react to wheel events (detached only).
    override func scrollWheel(with event: NSEvent) {}
}

/// Serializes a surface's PTY input/resize onto one ordered background queue with a
/// single reused `DaemonClient`. A fresh client per write on the concurrent global
/// queue (the old approach) could reorder bytes to the PTY and allocated needlessly;
/// this keeps writes ordered and off the main thread.
/// @unchecked Sendable: `DaemonClient` is itself thread-safe and `surfaceID` is immutable.
private final class SurfaceIO: @unchecked Sendable {
    private let client: DaemonClient
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
    /// Monotonic tag for coalescing live-resize votes: a real-time window drag fires one
    /// `resize(...)` per cell boundary, and the daemon re-`ioctl`s on every identical size, so a
    /// fast drag must not storm the IPC socket. Each call bumps this; a queued send drops itself if
    /// a newer call superseded it. Guarded by `lock`.
    private var resizeVoteEpoch: UInt64 = 0

    init(surfaceID: String, endpoint: Endpoint = .localControlSocket) {
        self.surfaceID = surfaceID
        self.client = DaemonClient(endpoint: endpoint)
    }

    /// Point input at the live subscription (or `nil` to fall back to the per-call client, e.g. when
    /// the pane is detached). Covers both first attach and re-grab.
    func attach(subscription: DaemonSubscription?) {
        lock.lock()
        self.subscription = subscription
        let rows = lastRows, cols = lastCols
        lock.unlock()
        // Re-assert the grid size on attach: a surface respawned by a restarted daemon comes up at
        // the daemon's placeholder size until a client resize vote arrives. Send it on the
        // subscription itself so the vote lives on the persistent fd (one-shot votes are dropped
        // the moment their socket closes, defeating smallest-of-attached-clients sizing).
        if let subscription, rows > 0, cols > 0 {
            queue.async { [surfaceID] in
                subscription.resize(surfaceID, rows: rows, cols: cols)
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
            // Prefer the persistent subscription fd. If it can't deliver — torn down, or the daemon
            // evicted this slow subscriber past its write-backlog cap while staying reachable —
            // `sendInput` returns false; fall back to a one-shot `.sendData` RPC on THIS queue
            // (mirrors the pre-subscription path, preserving keystroke order). Without this the
            // keystroke is silently dropped in the window between socket death and the main-thread
            // `attach(nil)`. No main hop.
            if let sub = self?.currentSubscription, sub.sendInput(data, surfaceID: surfaceID) {
                return
            }
            _ = try? client.request(.sendData(surfaceID: surfaceID, data: data))
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        lock.lock()
        lastRows = rows
        lastCols = cols
        resizeVoteEpoch &+= 1
        let epoch = resizeVoteEpoch
        lock.unlock()
        // Coalesce a live drag's per-cell-boundary votes: each call bumps the epoch, and the queued
        // send fires only if its epoch is still newest when it runs, reading the freshest size under
        // the lock. A burst on the IPC socket collapses to the final size — the daemon does not
        // dedupe identical `TIOCSWINSZ` calls, so the client must — while every DISTINCT settled
        // size still lands (the per-fd vote is sticky, so the last value wins).
        // Prefer the persistent subscription (mirrors `send`): the daemon keys size votes by fd, so
        // a vote on the subscription holds until detach — a one-shot vote evaporates with its
        // socket. Before the subscription exists, fall back to the per-call client (apply-then-drop
        // is correct for a not-yet-attached client).
        queue.async { [weak self, client, surfaceID] in
            guard let self else { return }
            self.lock.lock()
            let isLatest = epoch == self.resizeVoteEpoch
            let r = self.lastRows
            let c = self.lastCols
            self.lock.unlock()
            guard isLatest else { return } // a newer vote superseded this one — drop the duplicate
            if let sub = self.currentSubscription {
                sub.resize(surfaceID, rows: r, cols: c)
            } else {
                _ = try? client.request(.resizeSurface(surfaceID: surfaceID, rows: r, cols: c))
            }
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
    private let broadcastClient: DaemonClient
    private let broadcastQueue = DispatchQueue(label: "com.robert.harness.sync-input")
    private let lock = NSLock()
    private var siblingsStorage: [String] = []

    init(io: SurfaceIO, endpoint: Endpoint = .localControlSocket) {
        self.io = io
        self.broadcastClient = DaemonClient(endpoint: endpoint)
    }

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
