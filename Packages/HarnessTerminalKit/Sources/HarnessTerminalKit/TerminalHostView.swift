import AppKit
import Foundation
import HarnessCore
import HarnessTerminalEngine
import HarnessTheme

@MainActor
public protocol TerminalHostDelegate: AnyObject {
    func terminalHostDidChangeTitle(_ title: String, surfaceID: SurfaceID)
    func terminalHostDidChangeWorkingDirectory(_ path: String, surfaceID: SurfaceID)
    /// The pane's OSC 7 hostname changed (nil = no authority / reset) — drives per-host profiles.
    func terminalHostDidChangeRemoteHost(_ host: String?, surfaceID: SurfaceID)
    /// OSC 1337 `SetUserVar=` — optional: hosts that don't surface user variables ignore it.
    func terminalHostDidSetUserVariable(_ name: String, value: String, surfaceID: SurfaceID)
    /// RIS dropped the engine's user variables — optional: hosts that mirrored them clear their copies.
    func terminalHostDidClearUserVariables(surfaceID: SurfaceID)
    func terminalHostDidChangeFocus(_ focused: Bool, surfaceID: SurfaceID)
    func terminalHostDidRingBell(surfaceID: SurfaceID)
    /// A shell command finished (OSC 133) after running `duration` seconds, with `exitCode`.
    func terminalHostDidFinishCommand(duration: TimeInterval, exitCode: Int?, surfaceID: SurfaceID)
    func terminalHostDidRequestDesktopNotification(title: String, body: String, surfaceID: SurfaceID)
    /// ConEmu progress report (OSC 9;4) from the program in this pane — drives the tab's
    /// working indicator (Claude Code 2.0+ keep-alives one across each turn).
    func terminalHostDidUpdateProgress(_ report: TerminalProgressReport, surfaceID: SurfaceID)
    /// A `notify`-action output trigger matched `lineText` in this pane (already cooled down
    /// per rule by the surface).
    func terminalHostDidMatchTrigger(_ rule: TriggerRule, lineText: String, surfaceID: SurfaceID)
    func terminalHostDidClose(surfaceID: SurfaceID)
    /// A Lua action bound to a key in this pane finished: show its failure, run what it queued.
    func terminalHostScriptActionFinished(_ result: ScriptActionResult, surfaceID: SurfaceID)
    /// Another client took this pane's size, or gave it back (`owner` size mode).
    func terminalHostSizeOwnershipChanged(_ ownership: SizeOwnership, surfaceID: SurfaceID)
    /// Something the user should see that isn't an error dialog (a paste that didn't go through).
    func terminalHostShowMessage(_ message: String, surfaceID: SurfaceID)
}

extension TerminalHostDelegate {
    /// Default no-op — only the GUI surfaces user variables (as pane-scoped `@` options).
    public func terminalHostDidSetUserVariable(_ name: String, value: String, surfaceID: SurfaceID) {}
    /// Default no-op — only the GUI mirrors user variables, so only it has copies to clear.
    public func terminalHostDidClearUserVariables(surfaceID: SurfaceID) {}
    /// Default no-op so non-GUI conformers (e.g. the compositor) need not handle command timing.
    public func terminalHostDidFinishCommand(duration: TimeInterval, exitCode: Int?, surfaceID: SurfaceID) {}
    /// Default no-op — only the GUI tab strip renders progress.
    public func terminalHostDidUpdateProgress(_ report: TerminalProgressReport, surfaceID: SurfaceID) {}
    /// Default no-op — only the GUI evaluates per-host profiles.
    public func terminalHostDidChangeRemoteHost(_ host: String?, surfaceID: SurfaceID) {}
    /// Default no-op — only the GUI routes trigger notifications.
    public func terminalHostDidMatchTrigger(_ rule: TriggerRule, lineText: String, surfaceID: SurfaceID) {}
    /// Default no-op — only the GUI shows action failures and runs queued commands.
    public func terminalHostScriptActionFinished(_ result: ScriptActionResult, surfaceID: SurfaceID) {}
    public func terminalHostSizeOwnershipChanged(_ ownership: SizeOwnership, surfaceID: SurfaceID) {}
    public func terminalHostShowMessage(_ message: String, surfaceID: SurfaceID) {}
}

public struct TerminalHostResolvedAppearance: Equatable {
    public let canvasBackgroundHex: String
    public let canvasForegroundHex: String
    public let cursorHex: String
    public let outputPaletteHex: [String?]
    public let oscPaletteHex: [String?]?
    public let selectionBackgroundHex: String?
    public let selectionForegroundHex: String?
    public let cursorTextHex: String?
}

/// Hosts one terminal pane: Harness's native `HarnessTerminalSurfaceView` (GPU renderer +
/// engine) wired to the daemon-owned PTY. Input/resize go to the daemon; output is streamed
/// back and fed to the surface. The pane border/ring/mark overlays are drawn here.
@MainActor
public final class TerminalHostView: NSView {
    public let surfaceID: SurfaceID
    public weak var hostDelegate: TerminalHostDelegate?

    private let nativeView: HarnessTerminalSurfaceView
    private var scriptKeys: ScriptKeyConsumer?
    /// Which daemon this pane talks to — the local one by default, or a remote daemon (via an SSH
    /// tunnel) when the pane belongs to a connected remote host.
    private let daemonClient: DaemonClient
    private let io: SurfaceIO
    private let inputGate: InputGate
    private var outputSubscription: DaemonSubscription?
    /// How far this pane's terminal has read the daemon's output. A reconnect to the same
    /// daemon hands it back and gets only what it missed, with no reset or repaint.
    private var attachPoint: DaemonClient.AttachPoint?
    /// Bumped for every attach, so callbacks from a superseded one change nothing.
    private var attachGeneration = 0
    /// Where the history a resync is restoring ends (`beginHistoryRestore`). Bytes below it go
    /// to the restore, including the rest of it after a reconnect resumes mid-history.
    private var restoreEnd: UInt64?
    /// The daemon's latest word on who sizes this pane. Nil until this client has voted.
    public private(set) var sizeOwnership: SizeOwnership?
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

    /// Per-surface theme override (profiles): while set, this pane's CANVAS resolves through
    /// the named theme instead of the global one — window chrome keeps the global theme, and
    /// nothing is ever written back to settings (the audit roadmap's sanctioned per-surface
    /// override layer). nil = global theme. Pushed by the app when a `ProfileRule` matches
    /// or stops matching.
    public var profileThemeOverride: String? {
        didSet {
            guard profileThemeOverride != oldValue else { return }
            applyNativeAppearance()
        }
    }

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
    /// Hover-reveal × in the top-right corner (#168). Gated by `showsPaneCloseAffordance`
    /// (multi-pane tabs only) and revealed only while the pointer is in the corner region.
    private let paneCloseOverlay = PaneCloseOverlay()
    private var paneCloseHoverArea: NSTrackingArea?

    /// Fired when the user clicks the hover × — the app resolves this pane's `PaneID` and
    /// issues the regular kill-pane command, so behavior matches `prefix x` exactly.
    public var onPaneCloseRequested: (() -> Void)?

    /// Whether the hover × is armed. The app sets it on (re)mount: true only when the pane's
    /// tab has more than one pane — a single-pane tab already has the tab close button, and
    /// the pane stays chrome-free at rest either way.
    public var showsPaneCloseAffordance = false {
        didSet {
            guard showsPaneCloseAffordance != oldValue else { return }
            if !showsPaneCloseAffordance { paneCloseOverlay.setRevealed(false, animated: false) }
            updateTrackingAreas()
        }
    }
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
        let remote = RemoteAttach.isTunnel(endpoint)
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
        if remote {
            // The shell is on another Mac: a pasted image or file goes there first, and its
            // Kitty graphics can't name files on this one.
            nativeView.setReadsLocalGraphicsFiles(false)
            let client = daemonClient
            let surface = surfaceID
            nativeView.uploadForPaste = { [weak self] data, name, done in
                DispatchQueue.global(qos: .userInitiated).async {
                    let response = try? client.request(.writeTempFile(name: name, data: data), timeout: 30)
                    let path: String? = if case let .text(path)? = response { path } else { nil }
                    let failure: String? = switch response {
                    case .text?: nil
                    case let .error(message)?: "Couldn't paste \(name): \(message)"
                    default: "Couldn't paste \(name): the remote host didn't answer"
                    }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            if let failure { self?.hostDelegate?.terminalHostShowMessage(failure, surfaceID: surface) }
                            done(path)
                        }
                    }
                }
            }
        }
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
        let keys = scriptKeys ?? ScriptKeyConsumer { [weak self] request in
            guard let self else { return }
            let surfaceID = self.surfaceID
            ScriptActionRunner.run(request, origin: .key, surface: surfaceID.uuidString) { result in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.hostDelegate?.terminalHostScriptActionFinished(result, surfaceID: surfaceID)
                    }
                }
            }
        }
        scriptKeys = keys
        native.consumeScriptKey = { [weak keys] event in
            keys?.consume(event) ?? false
        }
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
        native.onTriggerMatched = { [weak self] rule, lineText in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidMatchTrigger(rule, lineText: lineText, surfaceID: self.surfaceID)
        }
        native.onPwd = { [weak self] path in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidChangeWorkingDirectory(path, surfaceID: self.surfaceID)
        }
        native.onRemoteHost = { [weak self] host in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidChangeRemoteHost(host, surfaceID: self.surfaceID)
        }
        native.onUserVar = { [weak self] name, value in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidSetUserVariable(name, value: value, surfaceID: self.surfaceID)
        }
        native.onUserVarsCleared = { [weak self] in
            guard let self else { return }
            self.hostDelegate?.terminalHostDidClearUserVariables(surfaceID: self.surfaceID)
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

        // Hover-reveal pane close — topmost overlay, pinned over the top-right corner. The
        // overlay is invisible (and click-through) except while the corner is hovered with the
        // affordance armed.
        addSubview(paneCloseOverlay)
        NSLayoutConstraint.activate([
            paneCloseOverlay.topAnchor.constraint(equalTo: topAnchor),
            paneCloseOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneCloseOverlay.widthAnchor.constraint(equalToConstant: PaneCloseOverlay.hoverRegionSize.width),
            paneCloseOverlay.heightAnchor.constraint(equalToConstant: PaneCloseOverlay.hoverRegionSize.height),
        ])
        paneCloseOverlay.onClose = { [weak self] in self?.onPaneCloseRequested?() }

        applyNativeAppearance()
    }

    /// Track the top-right corner region for the hover × (only while the affordance is armed —
    /// no tracking churn on single-pane tabs). AppKit re-invokes this on geometry changes.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = paneCloseHoverArea {
            removeTrackingArea(area)
            paneCloseHoverArea = nil
        }
        guard showsPaneCloseAffordance else { return }
        let size = PaneCloseOverlay.hoverRegionSize
        let corner = NSRect(
            x: max(0, bounds.maxX - size.width),
            y: isFlipped ? 0 : max(0, bounds.maxY - size.height),
            width: min(size.width, bounds.width),
            height: min(size.height, bounds.height)
        )
        let area = NSTrackingArea(
            rect: corner,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: ["paneClose": true]
        )
        addTrackingArea(area)
        paneCloseHoverArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        guard event.trackingArea === paneCloseHoverArea else {
            super.mouseEntered(with: event)
            return
        }
        guard showsPaneCloseAffordance else { return }
        paneCloseOverlay.setRevealed(true)
    }

    public override func mouseExited(with event: NSEvent) {
        guard event.trackingArea === paneCloseHoverArea else {
            super.mouseExited(with: event)
            return
        }
        paneCloseOverlay.setRevealed(false)
    }

    /// Push the full appearance to the surface, computed from the cached settings + theme.
    /// The canvas (default bg/fg/cursor) resolves through the SAME `ThemeManager.resolvedCanvas`
    /// the chrome uses, so terminal and chrome never seam. Program output keeps untouched/
    /// default ANSI colors unless `applyThemeToTerminalOutput` is on. The canvas is translucent
    /// when `backgroundOpacity` < 1 (window blur shows through); glyphs + explicit program
    /// backgrounds stay opaque.
    private func applyNativeAppearance() {
        guard let settings = cachedSettings else { return }
        var effectiveSettings = settings
        if profileThemeOverride != nil {
            // A matched profile's theme must render FAITHFULLY: the global custom canvas /
            // palette / selection overrides (and the macOS-system light/dark resolution)
            // describe the global theme, not this one — masked colors would defeat the
            // point of a "red over production ssh" profile.
            effectiveSettings.appearanceMode = .theme
            effectiveSettings.customBackgroundHex = nil
            effectiveSettings.customForegroundHex = nil
            effectiveSettings.customCursorHex = nil
            effectiveSettings.selectionBackgroundHex = nil
            effectiveSettings.selectionForegroundHex = nil
            effectiveSettings.cursorTextHex = nil
            effectiveSettings.boldColorHex = nil
            effectiveSettings.paletteHex = Array(repeating: nil, count: settings.paletteHex.count)
        }
        let resolved = Self.resolvedNativeAppearance(
            themeName: profileThemeOverride ?? cachedThemeName,
            settings: effectiveSettings,
            systemAppearance: Self.systemAppearance(for: effectiveAppearance)
        )
        // `window-style`/`pane-style`: a parsed base color overrides the canvas default for
        // this pane's default-colored cells (so an inactive pane dims). `.none` channels keep
        // the theme canvas. The active pane uses the `*-active-style` base.
        let styleBase = paneStyles.base(active: isActiveBorder)
        let canvasBg = Self.hexString(styleBase.bg) ?? resolved.canvasBackgroundHex
        let canvasFg = Self.hexString(styleBase.fg) ?? resolved.canvasForegroundHex
        nativeView.configureAppearance(
            fontFamily: settings.fontFamily,
            fontSize: CGFloat(settings.fontSize),
            vivid: settings.vividColors,
            colorRendering: settings.colorRendering,
            colorGamut: settings.colorGamut,
            canvasBackgroundHex: canvasBg,
            canvasForegroundHex: canvasFg,
            cursorHex: resolved.cursorHex,
            outputPaletteHex: resolved.outputPaletteHex,
            oscPaletteHex: resolved.oscPaletteHex,
            // Same paint opacity the sidebar veil uses, so the terminal and the
            // rail are one surface instead of a clear hole and a tinted panel.
            canvasOpacity: ChromeMaterial.paintOpacity(
                stored: settings.backgroundOpacity,
                appearanceMode: effectiveSettings.appearanceMode,
                systemAppearance: Self.systemAppearance(for: effectiveAppearance)
            ),
            cursorStyle: settings.cursorStyle,
            cursorBlink: settings.cursorBlink,
            paddingX: CGFloat(settings.windowPaddingX),
            paddingY: CGFloat(settings.windowPaddingY),
            paddingBalance: settings.windowPaddingBalance,
            selectionBackgroundHex: resolved.selectionBackgroundHex,
            selectionForegroundHex: resolved.selectionForegroundHex,
            cursorTextHex: resolved.cursorTextHex,
            copyOnSelect: settings.copyOnSelect,
            pasteProtection: settings.pasteProtection,
            scrollbackLines: settings.scrollbackLines,
            linearBlending: settings.linearBlending,
            textRendering: settings.textRendering,
            ligatures: settings.ligatures,
            minimumContrast: HarnessSettings.clampedContrast(settings.minimumContrast),
            themeFit: settings.effectiveThemeFit(
                appearanceIsLight: RGBColor(hex: canvasBg)?.isDark == false
            ),
            boldIsBright: settings.boldIsBright,
            promptGutter: settings.showPromptGutter,
            offMainParserFramePipeline: settings.offMainParserFramePipeline,
            liveResizeReflow: settings.liveResizeReflow
        )
        // Behavior (not appearance) settings — set directly rather than bloating the appearance call.
        nativeView.scrollMultiplier = CGFloat(HarnessSettings.clampedScrollMultiplier(settings.scrollMultiplier))
        nativeView.mouseHideWhileTyping = settings.mouseHideWhileTyping
        nativeView.optionAsMeta = settings.optionAsMeta
        // Resize overlay: legible on any theme via the canvas FG fill + BG text (same trick as the
        // pane-border label), positioned per settings.
        resizeHUD.applyColors(
            text: Self.nsColor(hex: canvasBg, fallback: .windowBackgroundColor),
            fill: Self.nsColor(hex: canvasFg, fallback: .labelColor)
        )
        scrollbar.applyColor(Self.nsColor(hex: canvasFg, fallback: .labelColor))
        paneCloseOverlay.applyColor(Self.nsColor(hex: canvasFg, fallback: .labelColor))
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

    private static func systemAppearance(for appearance: NSAppearance) -> HarnessSystemAppearance {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// The colors a pane paints with. Public so Settings previews exactly what the panes show.
    public static func resolvedNativeAppearance(
        themeName: String,
        settings: HarnessSettings,
        systemAppearance: HarnessSystemAppearance
    ) -> TerminalHostResolvedAppearance {
        let colorTheme = ThemeManager.activeThemeName(
            themeName: themeName,
            appearanceMode: settings.appearanceMode,
            systemAppearance: systemAppearance,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName
        )
        let appearance = ThemeManager.resolvedAppearance(
            themeName: themeName,
            appearanceMode: settings.appearanceMode,
            systemAppearance: systemAppearance,
            systemLightThemeName: settings.systemLightThemeName,
            systemDarkThemeName: settings.systemDarkThemeName,
            customBackgroundHex: settings.customBackgroundHex,
            customForegroundHex: settings.customForegroundHex,
            customCursorHex: settings.customCursorHex
        )
        return TerminalHostResolvedAppearance(
            canvasBackgroundHex: appearance.canvas.backgroundHex,
            canvasForegroundHex: appearance.canvas.foregroundHex,
            cursorHex: appearance.canvas.cursorHex,
            outputPaletteHex: nativeOutputPaletteHex(
                settings: settings,
                appearance: appearance,
                systemAppearance: systemAppearance
            ),
            oscPaletteHex: nativeOSCPaletteHex(settings: settings, appearance: appearance),
            selectionBackgroundHex: settings.selectionBackgroundHex
                ?? ThemeManager.selectionBackgroundHex(themeName: colorTheme),
            selectionForegroundHex: settings.selectionForegroundHex
                ?? ThemeManager.selectionForegroundHex(themeName: colorTheme),
            cursorTextHex: settings.cursorTextHex
                ?? ThemeManager.cursorTextHex(themeName: colorTheme)
        )
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

    /// The 16 ANSI colors used for terminal *output*. Light canvases, including
    /// follow-macOS while the system is light, use the light theme palette.
    /// In theme mode, with "apply theme to output" on, an explicit slot wins and
    /// empty slots take the named theme. Otherwise empty slots stay nil.
    private static func nativeOutputPaletteHex(
        settings: HarnessSettings,
        appearance: ThemeManager.ResolvedAppearance,
        systemAppearance: HarnessSystemAppearance
    ) -> [String?] {
        // Light canvases have their own palette, including follow-macOS while the
        // system is light. A stored dark palette (ef-bio, imported for Theme mode)
        // paints light-on-dark inks on that canvas, so program colors collapse to gray.
        let lightCanvas = settings.appearanceMode == .light
            || (settings.appearanceMode == .macOSSystem && systemAppearance == .light)
        if lightCanvas {
            return appearance.paletteHex
        }
        let explicit = HarnessSettings.normalizedPalette(settings.paletteHex)
        // An imported palette fills only the empty slots, and only in theme mode.
        if settings.appearanceMode == .theme, settings.applyThemeToTerminalOutput {
            return (0 ..< 16).map { explicit[$0] ?? appearance.paletteHex[$0] }
        }
        return explicit
    }

    private static func nativeOSCPaletteHex(
        settings: HarnessSettings,
        appearance: ThemeManager.ResolvedAppearance
    ) -> [String?]? {
        settings.appearanceMode == .macOSSystem ? appearance.paletteHex : nil
    }

    /// Clip this pane's metal surface to the island radius. The mask has to live on
    /// the `CAMetalLayer`; the AppKit parent's `masksToBounds` does not clip it.
    public func applyIslandCornerRadius(_ radius: CGFloat) {
        nativeView.applyIslandCornerRadius(radius)
    }

    public func applyTheme(named name: String) {
        cachedThemeName = name
        applyNativeAppearance()
    }

    private var appliedTriggers: [TriggerRule]?

    public func applySettings(_ settings: HarnessSettings) {
        cachedSettings = settings
        applyNativeAppearance()
        // Output triggers: recompiled when they change (reload-on-save applies them live).
        if appliedTriggers != settings.triggers {
            appliedTriggers = settings.triggers
            nativeView.applyTriggerRules(settings.triggers)
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if HarnessEffectiveAppearanceRefreshPolicy.shouldRefreshOnEffectiveAppearanceChange(
            appearanceMode: cachedSettings?.appearanceMode ?? .theme
        ) {
            applyNativeAppearance()
        }
    }

    /// Honor tmux `set-clipboard`: when false, programs cannot set the system
    /// clipboard via OSC 52. Default on (tmux's default); the app sets it from the
    /// daemon option.
    public var allowProgramClipboardAccess: Bool {
        get { nativeView.allowProgramClipboardAccess }
        set { nativeView.allowProgramClipboardAccess = newValue }
    }

    /// `allow-clipboard-read`: programs may read the clipboard via OSC 52. Default off.
    public var allowProgramClipboardRead: Bool {
        get { nativeView.allowProgramClipboardRead }
        set { nativeView.allowProgramClipboardRead = newValue }
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

    /// Visual bell — flash the surface (the `visual` channel of the bell feedback). The decision of
    /// *whether* to flash lives in `SessionCoordinator` (settings + tmux options); this just paints.
    public func flashBell() {
        nativeView.flashBell()
    }

    // MARK: - Find (Cmd+F)

    private var findBar: TerminalFindBar?
    private var findTopConstraint: NSLayoutConstraint?
    private var findTrailingConstraint: NSLayoutConstraint?

    public var gridCellCount: (rows: Int, columns: Int) { nativeView.gridCellCount }

    public var outputGeneration: UInt64 { nativeView.outputGeneration }
    public var thumbnailStyle: TerminalThumbnailStyle { nativeView.thumbnailStyle }
    public func thumbnail(_ done: @escaping @MainActor @Sendable (TerminalThumbnail) -> Void) {
        nativeView.thumbnail(done)
    }

    public var copyModeWordSeparators: String {
        get { nativeView.copyModeWordSeparators }
        set { nativeView.copyModeWordSeparators = newValue }
    }

    /// False when this view is not the size owner. The surface then reflows locally.
    public var sizeOwner: Bool {
        get { nativeView.sizeOwner }
        set { nativeView.sizeOwner = newValue }
    }

    public override func layout() {
        super.layout()
        nudgeFindBar()
    }

    /// Toggle the in-pane find bar. Opening focuses its field (keystrokes go to the bar, not
    /// the shell); closing clears highlights and returns focus to the terminal.
    public func toggleFind() {
        if findBar != nil { hideFind() } else { showFind() }
    }

    /// ⌘G / ⇧⌘G from anywhere in the pane: the next or previous match, opening the find
    /// bar when it's closed.
    public func findNext() {
        guard findBar != nil else { return showFind() }
        nativeView.findNext()
    }

    public func findPrevious() {
        guard findBar != nil else { return showFind() }
        nativeView.findPrevious()
    }

    private func showFind() {
        guard findBar == nil else { findBar?.focusField(); return }
        let bar = TerminalFindBar()
        bar.onQueryChanged = { [weak self, weak bar] query in
            self?.nativeView.updateFind(query: query, options: bar?.searchOptions ?? .default)
        }
        bar.onNext = { [weak self] in self?.nativeView.findNext() }
        bar.onPrevious = { [weak self] in self?.nativeView.findPrevious() }
        bar.onClose = { [weak self] in self?.hideFind() }
        addSubview(bar)
        let top = bar.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        let trailing = bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            top,
            trailing,
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
        ])
        findTopConstraint = top
        findTrailingConstraint = trailing
        nativeView.onFindResultsChanged = { [weak self, weak bar] current, total in
            bar?.setResults(current: current, total: total)
            self?.nudgeFindBar()
        }
        nativeView.beginFind()
        findBar = bar
        bar.focusField()
        nudgeFindBar()
    }

    /// Move the overlay when it covers the current match. Row count is not an input.
    private func nudgeFindBar() {
        guard let bar = findBar, let top = findTopConstraint, let trailing = findTrailingConstraint else { return }
        let match = nativeView.currentFindMatchRect().map { convert($0, from: nativeView) }
        let placed = FindBarNudge.place(
            viewportWidth: bounds.width,
            viewportHeight: bounds.height,
            barWidth: max(bar.fittingSize.width, bar.bounds.width),
            barHeight: max(bar.fittingSize.height, bar.bounds.height, 1),
            match: match.map { rect in
                FindBarNudge.Box(
                    x: rect.minX,
                    y: bounds.height - rect.maxY,
                    width: rect.width,
                    height: rect.height
                )
            }
        )
        top.constant = placed.y
        trailing.constant = -(bounds.width - (placed.x + placed.width))
    }

    private func hideFind() {
        guard let bar = findBar else { return }
        nativeView.onFindResultsChanged = nil
        nativeView.endFind()
        bar.removeFromSuperview()
        findBar = nil
        findTopConstraint = nil
        findTrailingConstraint = nil
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
        // Short-circuit only when ALREADY intentionally detached (true idempotency). Guarding on a
        // nil subscription instead would early-return during a daemon-crash reconnect (the stream
        // already dropped `outputSubscription` to nil) WITHOUT setting `intentionallyDetached` — so
        // the in-flight reconnect's `onAttached`, which gates on `!intentionallyDetached`, would
        // re-grab the surface the user explicitly released. Setting the flag tears the reconnect
        // down: its probe drops its subscription and no further retries are scheduled.
        guard !intentionallyDetached else { return }
        intentionallyDetached = true // suppress auto-reconnect: this detach is deliberate
        outputSubscription?.cancel()
        outputSubscription = nil
        io.attach(subscription: nil) // fall back to the per-call client while detached
        hideReconnectingOverlay() // a deliberate release supersedes any in-flight reconnect cue
        showDetachedOverlay()
    }

    /// Re-grab a surface released with `detachFromDaemonSurface()`: reattach from where the pane
    /// left off so it catches up. No-op if still attached.
    public func reattachToDaemonSurface() {
        guard outputSubscription == nil else { return }
        intentionallyDetached = false
        reconnectAttempts = 0
        hideReconnectingOverlay()
        hideDetachedOverlay()
        startDaemonOutput()
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
    /// Select the last finished command's output (OSC 133 marks; no-op without them).
    public func selectLastCommandOutput() { nativeView.selectLastCommandOutput() }

    /// `synchronize-panes`: the surface-id strings (excluding this pane) that this
    /// pane's input should also be mirrored to. Empty = normal single-pane input.
    public func setSyncSiblings(_ surfaceIDStrings: [String]) {
        inputGate.setSiblings(surfaceIDStrings)
    }

    /// Returns true iff the daemon acknowledged the surface (`.ok`). Reconnect gates resubscribe on
    /// this so it never subscribes to a surface the (still-restarting) daemon hasn't recreated yet.
    /// Byte budget the daemon ring uses for a line cap. `0` is the unlimited sentinel
    /// the daemon maps to `ScrollbackBudget.unlimitedSafetyCapBytes`. Any positive
    /// count is sized at `ScrollbackBudget.bytesPerLine` bytes per line.
    static func scrollbackBytes(forLines lines: Int) -> Int {
        lines == 0 ? 0 : lines * ScrollbackBudget.bytesPerLine
    }

    /// GUI history lines allowed for a daemon replay ring of `bytes`. `bytes <= 0`
    /// is the unlimited sentinel and becomes the shared safety ceiling, not an
    /// unbounded GUI history (`maxHistoryLines == 0` means unlimited in the emulator).
    public static func historyLineCap(daemonScrollbackBytes bytes: Int) -> Int {
        ScrollbackBudget.lineCap(daemonScrollbackBytes: bytes)
    }

    @discardableResult
    private func ensureDaemonSurface(cwd: String?, shell: String, settings: HarnessSettings?) -> Bool {
        do {
            if case .ok = try daemonClient.request(.ensureSurface(
                surfaceID: surfaceID.uuidString,
                cwd: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
                shell: shell,
                rows: 24,
                cols: 80,
                scrollbackBytes: Self.scrollbackBytes(forLines: settings?.scrollbackLines ?? 10_000)
            )) {
                return true
            }
        } catch {
            fputs("Harness: ensureSurface failed for \(surfaceID.uuidString): \(error)\n", harnessStderr)
        }
        return false
    }

    private func startDaemonOutput() {
        let (onStart, onData) = makeAttachHandlers()
        do {
            outputSubscription = try daemonClient.attach(
                surfaceID: surfaceID.uuidString,
                label: "Harness.app",
                resume: attachPoint,
                onStart: onStart,
                onData: onData,
                onOwnership: makeOwnershipHandler(),
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

    /// The attach callbacks, shared by the first connect, a re-grab, and a reconnect. They run
    /// on the subscription's read thread and hop to main IN ORDER: the read loop is serial and
    /// `DispatchQueue.main.async` is strict FIFO, so the emulator sees the daemon's byte order.
    /// (An unstructured `Task { @MainActor in }` is not order-preserving and scrambled
    /// cursor-positioned redraws under bursty output.) A resync paints the daemon's screen at
    /// once and rebuilds the history behind it; the bytes a resume missed are fed as a replay
    /// so old bells and queries don't fire again (#168).
    private func makeAttachHandlers() -> (
        onStart: @Sendable (DaemonClient.AttachStart) -> Void,
        onData: @Sendable (Data, UInt64) -> Void
    ) {
        attachGeneration += 1
        let generation = attachGeneration
        let progress = AttachProgress()
        let onStart: @Sendable (DaemonClient.AttachStart) -> Void = { [weak self] start in
            progress.historyEnd = start.historyEnd
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.attachGeneration, !self.intentionallyDetached else { return }
                    self.attachPoint = start.point
                    if start.resync {
                        self.restoreEnd = start.historyEnd
                        self.nativeView.beginHistoryRestore(screen: start.screen)
                    }
                }
            }
        }
        let onData: @Sendable (Data, UInt64) -> Void = { [weak self] data, sequence in
            let replay = sequence < progress.historyEnd
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, generation == self.attachGeneration else { return }
                    let end = sequence &+ UInt64(data.count)
                    if let restoreEnd = self.restoreEnd, sequence < restoreEnd {
                        self.nativeView.receiveHistory(data)
                        if end >= restoreEnd { self.finishHistoryRestore() }
                    } else {
                        self.finishHistoryRestore()
                        self.nativeView.receive(data, replay: replay)
                    }
                    self.attachPoint?.sequence = end
                }
            }
        }
        return (onStart, onData)
    }

    private func finishHistoryRestore() {
        guard restoreEnd != nil else { return }
        restoreEnd = nil
        nativeView.finishHistoryRestore()
    }

    /// Ownership frames: a non-owner stops resizing the PTY (it reflows locally, or shows the
    /// owner's grid on the alternate screen, where programs draw for that size).
    private func makeOwnershipHandler() -> @Sendable (SizeOwnership) -> Void {
        { [weak self] ownership in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sizeOwnership = ownership
                    self.nativeView.sizeOwner = ownership.owner
                    self.nativeView.answersQueries = ownership.responder ?? ownership.owner
                    if !ownership.owner {
                        self.nativeView.adoptOwnerSize(cols: Int(ownership.cols), rows: Int(ownership.rows))
                    }
                    self.hostDelegate?.terminalHostSizeOwnershipChanged(ownership, surfaceID: self.surfaceID)
                }
            }
        }
    }

    /// Make this window's size the pane's size (`owner` mode). Off main; the daemon pushes
    /// the new ownership back.
    public func takeSize() {
        guard let clientID = sizeOwnership?.clientID else { return }
        let client = daemonClient
        let sid = surfaceID.uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? client.request(.takeSurface(surfaceID: sid, clientID: clientID))
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
    /// reattach (resuming when the daemon is the same one). Bounded backoff covers the restart window; after that, fall
    /// back to the manual "click to re-grab" affordance. No-op once intentionally detached.
    private func scheduleDaemonReconnect() {
        guard !intentionallyDetached, outputSubscription == nil else { return }
        guard !DaemonReconnectPolicy.isExhausted(attempts: reconnectAttempts) else {
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
        let delay = DaemonReconnectPolicy.delay(forAttempt: attempt)
        // Capture main-actor state so the whole probe + (re)attach handshake — ping, ensureSurface,
        // and attach — runs OFF main. A still-restarting daemon answers slowly
        // (or its socket blocks), so doing these synchronous round trips on main froze the UI for the
        // duration of every retry. Only the view touches (RIS reset, replay receive, subscription
        // assignment, `io.attach`) hop back to main.
        let client = daemonClient
        let sid = surfaceID.uuidString
        let cwd = cachedCwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        let shell = cachedShell
        let scrollbackBytes = Self.scrollbackBytes(forLines: cachedSettings?.scrollbackLines ?? 10_000)
        let (onStart, onData) = makeAttachHandlers()
        let onOwnership = makeOwnershipHandler()
        let onEnd = makeOutputEndHandler()
        let resume = attachPoint
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
            // Same daemon: resume from the last byte painted. A restarted daemon (new epoch) or an
            // evicted gap resyncs: reset, then the full history.
            let subscription = try? client.attach(
                surfaceID: sid, label: "Harness.app", resume: resume, onStart: onStart, onData: onData,
                onOwnership: onOwnership, onEnd: onEnd
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
    /// Coalescing buffer for the per-call `.sendData` fallback (used only when the persistent
    /// subscription can't deliver — torn down, or evicted for slowness — e.g. during a daemon
    /// restart). Each fallback `client.request` connects + blocks reading; an SSH-tunnel endpoint
    /// `connect()`s even when the remote daemon is gone, so a naïve per-keystroke fallback replays
    /// N keystrokes as N × the read timeout in a stalled burst. Instead we accumulate all bytes
    /// awaiting a fallback here and drain them as ONE ordered request per attempt. Guarded by `lock`.
    private var pendingFallback = Data()
    /// Whether a fallback drain is already enqueued on `queue`; keeps `send` from piling up one
    /// blocking request per keystroke. Guarded by `lock`.
    private var fallbackDrainScheduled = false
    /// Short read timeout for the fallback request. The persistent subscription is the real input
    /// path; the fallback only covers the brief window between subscription death and the
    /// main-thread `attach(nil)`, so it must fail fast (not the default 2 s) to avoid stalling the
    /// serial input queue while a daemon is down.
    private let fallbackTimeout: TimeInterval = 0.3

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
        // Schedule a drain through the fresh subscription for any bytes that fell back while it was
        // down, unless one is already pending (avoid two concurrent drains).
        let scheduleDrain = subscription != nil && !pendingFallback.isEmpty && !fallbackDrainScheduled
        if scheduleDrain { fallbackDrainScheduled = true }
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
        // Flush any buffered fallback input through the recovered subscription, in order.
        // `drainFallback` clears `fallbackDrainScheduled` itself.
        if scheduleDrain {
            queue.async { [weak self] in self?.drainFallback() }
        }
    }

    private var currentSubscription: DaemonSubscription? {
        lock.lock(); defer { lock.unlock() }; return subscription
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        // Stay on `queue` so keystrokes are ordered and off the main thread (matching the old
        // path); the write itself is now one frame on the persistent fd with no socket setup or
        // reply wait. Before the subscription exists (first keystrokes), fall back to the client.
        queue.async { [weak self, surfaceID] in
            guard let self else { return }
            // Once any byte is awaiting a fallback drain, ALL later bytes must queue behind it —
            // even if the subscription has recovered — or they'd jump ahead and reorder input. So
            // check the pending buffer first, under the lock.
            self.lock.lock()
            let draining = !self.pendingFallback.isEmpty || self.fallbackDrainScheduled
            self.lock.unlock()
            if !draining,
               let sub = self.currentSubscription,
               sub.sendInput(data, surfaceID: surfaceID) {
                // Healthy fast path: one frame on the persistent fd, no socket setup or reply wait.
                return
            }
            // Subscription can't deliver — torn down, evicted for slowness, or not yet attached.
            // Buffer the bytes and ensure exactly one coalescing drain is scheduled, so N keystrokes
            // during an outage produce ordered single-request attempts instead of N blocking RPCs.
            self.enqueueFallback(data)
        }
    }

    /// Append `data` to the fallback buffer and schedule one drain if none is pending. Runs on
    /// `queue`. Coalesces a burst of keystrokes (during subscription loss / daemon restart) into a
    /// single ordered `.sendData` request per attempt, bounding the stall to one `fallbackTimeout`.
    private func enqueueFallback(_ data: Data) {
        lock.lock()
        pendingFallback.append(data)
        guard !fallbackDrainScheduled else { lock.unlock(); return }
        fallbackDrainScheduled = true
        lock.unlock()
        queue.async { [weak self] in self?.drainFallback() }
    }

    /// Drain the coalesced fallback buffer in order. Prefers a recovered subscription; otherwise
    /// one short-timeout `.sendData` RPC carrying everything buffered. On failure the bytes stay
    /// buffered and the next `send` re-schedules a drain (single retry per keystroke burst, never
    /// N × timeout). Runs on `queue`.
    private func drainFallback() {
        lock.lock()
        let batch = pendingFallback
        pendingFallback.removeAll(keepingCapacity: true)
        fallbackDrainScheduled = false
        lock.unlock()
        guard !batch.isEmpty else { return }

        if let sub = currentSubscription, sub.sendInput(batch, surfaceID: surfaceID) {
            return // subscription recovered — delivered in order, buffer already cleared
        }
        do {
            _ = try client.request(.sendData(surfaceID: surfaceID, data: batch), timeout: fallbackTimeout)
        } catch {
            // Still unreachable (e.g. daemon mid-restart): re-buffer this batch AHEAD of anything
            // that accumulated while the request was in flight, preserving byte order. We do NOT
            // auto-re-arm here — that would busy-spin one fallbackTimeout request after another
            // while the daemon is down. The next `send` re-schedules a drain (so a typing user
            // keeps retrying once per keystroke), and `attach()` flushes on reattach, so buffered
            // bytes are never stranded once delivery is possible again.
            lock.lock()
            pendingFallback = batch + pendingFallback
            lock.unlock()
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

/// Pure backoff policy for `TerminalHostView.scheduleDaemonReconnect`, extracted so the recovery
/// window's shape — bounded retries, ramping delay, hand-off to the manual re-grab overlay — is
/// pinned by unit tests (the live wiring needs a real daemon and is covered by the gated suites).
enum DaemonReconnectPolicy {
    static let maxAttempts = 60

    /// Ramp 0.1s → 1.0s: a fast daemon restart reattaches almost immediately, a slow one isn't
    /// hammered; the full window is ~55s before the manual re-grab affordance takes over.
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        min(0.1 * Double(attempt + 1), 1.0)
    }

    static func isExhausted(attempts: Int) -> Bool { attempts >= maxAttempts }
}

/// The history boundary of one attach, written by `onStart` and read by `onData`, both on the
/// subscription's serial read thread.
private final class AttachProgress: @unchecked Sendable {
    var historyEnd: UInt64 = 0
}
