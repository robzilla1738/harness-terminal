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
    /// Theme-derived indicator colors. This package can't reach the app's palette,
    /// so the app pushes them via `applyBorderColors`. Default until the first push.
    public var activeBorderColor: NSColor = .systemBlue
    public var waitingRingColor: NSColor = .systemBlue

    public var showsWaitingRing: Bool {
        get { isWaiting }
        set {
            isWaiting = newValue
            needsDisplay = true
        }
    }

    public var showsActiveBorder: Bool {
        get { isActiveBorder }
        set {
            let changed = newValue != isActiveBorder
            isActiveBorder = newValue
            needsDisplay = true
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
    private let borderLabelField = NSTextField(labelWithString: "")
    private var borderLabelTop: NSLayoutConstraint?
    private var borderLabelBottom: NSLayoutConstraint?

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
            needsDisplay = true
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
        let surfaceEnv = harnessSurfaceEnv ?? surfaceID.uuidString
        let io = SurfaceIO(surfaceID: surfaceEnv)
        self.io = io
        let inputGate = InputGate(io: io)
        self.inputGate = inputGate
        let nativeView = HarnessTerminalSurfaceView(
            themeName: themeName,
            fontFamily: settings?.fontFamily ?? "Menlo",
            fontSize: CGFloat(settings?.fontSize ?? 14),
            vivid: settings?.vividColors ?? true
        )
        self.nativeView = nativeView
        super.init(frame: .zero)
        ensureDaemonSurface(cwd: workingDirectory, shell: shell, settings: settings)
        configureNative(nativeView, io: io, inputGate: inputGate)
        startDaemonOutput()
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

        // pane-border-format label overlay — added AFTER `native` so it sits above the Metal
        // surface (a label drawn in `draw(_:)` would be hidden behind it).
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
            ligatures: settings.ligatures
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

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The waiting ring (urgent) takes precedence over the quieter active-pane
        // border so a pane that needs attention never reads as merely focused.
        if isWaiting {
            // Two-stroke ring: a soft outer halo + a crisp inner stroke. Reads as
            // "needs attention" without screaming.
            strokeIndicator(color: waitingRingColor, lineWidth: 4, alpha: 0.18, inset: 1)
            strokeIndicator(color: waitingRingColor, lineWidth: 1.5, alpha: 0.85, inset: 2)
        } else if isActiveBorder {
            // Minimal focused-pane hairline — only ever drawn when a tab is split
            // (gated in SessionCoordinator.setActiveSurface), so a lone terminal has
            // no border at all. Two strokes give it a subtle "edge light" on dark
            // themes without becoming a hard outline.
            strokeIndicator(color: activeBorderColor, lineWidth: 1, alpha: 0.42, inset: 1)
        }
        // The marked pane (join-pane source) gets a distinct dashed accent on top,
        // so it reads as "marked" independently of focus.
        if isMarked {
            let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0)
            waitingRingColor.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }

    private func strokeIndicator(color: NSColor, lineWidth: CGFloat, alpha: CGFloat, inset: CGFloat? = nil) {
        let effectiveInset = inset ?? lineWidth
        let rect = bounds.insetBy(dx: effectiveInset, dy: effectiveInset)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        color.withAlphaComponent(alpha).setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }

    /// Push theme-derived indicator colors from the app's palette.
    public func applyBorderColors(active: NSColor, waiting: NSColor) {
        activeBorderColor = active
        waitingRingColor = waiting
        needsDisplay = true
    }

    public func focusTerminal() {
        window?.makeFirstResponder(nativeView)
        hostDelegate?.terminalHostDidChangeFocus(true, surfaceID: surfaceID)
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
        outputSubscription?.cancel()
        outputSubscription = nil
    }

    /// Re-grab a surface released with `detachFromDaemonSurface()`: resubscribe and replay
    /// scrollback so the pane catches up. No-op if still attached.
    public func reattachToDaemonSurface() {
        guard outputSubscription == nil else { return }
        startDaemonOutput()
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

    private func ensureDaemonSurface(cwd: String?, shell: String, settings: HarnessSettings?) {
        do {
            _ = try daemonClient.request(.ensureSurface(
                surfaceID: surfaceID.uuidString,
                cwd: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
                shell: shell,
                rows: 24,
                cols: 80,
                scrollbackBytes: (settings?.scrollbackLines ?? 10_000) * 160
            ))
        } catch {
            fputs("Harness: ensureSurface failed for \(surfaceID.uuidString): \(error)\n", stderr)
        }
    }

    private func startDaemonOutput() {
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
                label: "Harness.app"
            ) { [weak self] data, _ in
                Task { @MainActor in
                    self?.nativeView.receive(data)
                }
            }
        } catch {
            fputs("Harness: output subscription failed for \(surfaceID.uuidString): \(error)\n", stderr)
        }
    }

    deinit {
        outputSubscription?.cancel()
    }
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

    init(surfaceID: String) { self.surfaceID = surfaceID }

    func send(_ data: Data) {
        queue.async { [client, surfaceID] in
            _ = try? client.request(.sendData(surfaceID: surfaceID, data: data))
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
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
