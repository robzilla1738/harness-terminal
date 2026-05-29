import AppKit
import Foundation
import GhosttyTerminal
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

@MainActor
public final class TerminalHostView: NSView {
    public let surfaceID: SurfaceID
    public weak var hostDelegate: TerminalHostDelegate?

    private let terminalView: TerminalView
    private let controller: TerminalController
    private let memorySession: InMemoryTerminalSession
    private let daemonClient = DaemonClient()
    private let io: SurfaceIO
    private let inputGate: InputGate
    private var outputSubscription: DaemonSubscription?
    private var isWaiting = false
    private var isActiveBorder = false
    private var appliedThemeBackgroundHex: String?
    private var cachedSettings: HarnessSettings?
    private var cachedThemeName: String
    /// Theme-derived indicator colors. This package can't reach the app's palette,
    /// so the app pushes them via `applyBorderColors`. Default until the first push.
    public var activeBorderColor: NSColor = .systemBlue
    public var waitingRingColor: NSColor = .systemBlue

    /// Empty libghostty theme section. Harness themes must never override
    /// terminal output colors; terminal tools should render with Ghostty/base
    /// config ANSI and truecolor behavior.
    private static let emptyControllerTheme = TerminalTheme()

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
            isActiveBorder = newValue
            needsDisplay = true
        }
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
        themeName: String = ThemeManager.defaultThemeName,
        controller: TerminalController? = nil
    ) {
        self.surfaceID = surfaceID
        self.cachedThemeName = themeName
        let shell = settings?.defaultShell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let surfaceEnv = harnessSurfaceEnv ?? surfaceID.uuidString
        let io = SurfaceIO(surfaceID: surfaceEnv)
        self.io = io
        let inputGate = InputGate(io: io)
        self.inputGate = inputGate
        self.memorySession = InMemoryTerminalSession(
            write: { data in inputGate.route(data) },
            resize: { viewport in io.resize(rows: viewport.rows, cols: viewport.columns) }
        )
        self.cachedSettings = settings
        self.controller = controller ?? Self.makeController(settings: settings, themeName: themeName)
        terminalView = TerminalView(frame: .zero)
        super.init(frame: .zero)
        ensureDaemonSurface(cwd: workingDirectory, shell: shell, settings: settings)
        configure(workingDirectory: workingDirectory, settings: settings)
        startDaemonOutput()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeController(settings: HarnessSettings?, themeName: String) -> TerminalController {
        let terminalConfiguration = makeTerminalConfiguration(settings: settings, themeName: themeName)
        return TerminalController(
            configuration: terminalConfiguration,
            theme: emptyControllerTheme
        )
    }

    /// Single merged terminal block: Ghostty/base config → color pipeline →
    /// settings. Named Harness themes are intentionally absent from terminal
    /// output so they cannot wash or retint terminal tools.
    static func makeTerminalConfiguration(
        settings: HarnessSettings?,
        themeName: String
    ) -> TerminalConfiguration {
        TerminalConfiguration {
            configureTerminalBuilder(&$0, settings: settings, themeName: themeName)
        }
    }

    private static func configureTerminalBuilder(
        _ builder: inout TerminalConfiguration.Builder,
        settings: HarnessSettings?,
        themeName: String
    ) {
        builder.withCustom("shell-integration", "detect")
        builder.withCustom("shell-integration-features", "sudo,title")
        TerminalColorPipeline.apply(to: &builder)
        guard let settings else { return }
        builder.withFontSize(settings.fontSize)
        builder.withFontFamily(settings.fontFamily)
        // Color translucency only. Blur is applied once at the window level (CGS),
        // not per-surface: libghostty's background-blur is a no-op in embedded mode
        // (it doesn't own the NSWindow) and would otherwise double the chrome blur.
        builder.withBackgroundOpacity(Double(settings.backgroundOpacity))
        builder.withWindowPaddingX(Int(settings.windowPaddingX.rounded()))
        builder.withWindowPaddingY(Int(settings.windowPaddingY.rounded()))
        // Canvas bg/fg/cursor come from the one shared resolver so the terminal
        // surface always matches the chrome (no seam between sidebar and output).
        let canvas = ThemeManager.resolvedCanvas(
            themeName: themeName,
            customBackgroundHex: settings.customBackgroundHex,
            customForegroundHex: settings.customForegroundHex,
            customCursorHex: settings.customCursorHex
        )
        builder.withBackground(canvas.backgroundHex)
        builder.withForeground(canvas.foregroundHex)
        builder.withCursorColor(canvas.cursorHex)
        // Full Ghostty-parity color set. nil = let libghostty derive from bg/fg
        // (its native default); a value is pushed verbatim. Picking a theme seeds
        // these into settings, so a chosen theme renders its complete palette.
        if let value = settings.cursorTextHex { builder.withCursorText(value) }
        if let value = settings.selectionBackgroundHex { builder.withSelectionBackground(value) }
        if let value = settings.selectionForegroundHex { builder.withSelectionForeground(value) }
        if let value = settings.boldColorHex { builder.withBoldColor(value) }
        if settings.minimumContrast > 1 { builder.withMinimumContrast(settings.minimumContrast) }
        for (index, hex) in settings.paletteHex.enumerated() {
            if let hex { builder.withPalette(index, color: hex) }
        }
        builder.withCursorStyle(TerminalCursorStyle(rawValue: settings.cursorStyle) ?? .block)
        builder.withCursorStyleBlink(settings.cursorBlink)
        builder.withCustom("copy-on-select", settings.copyOnSelect ? "true" : "false")
    }

    private func pushConfiguration() {
        guard let cachedSettings else { return }
        _ = controller.setTerminalConfiguration(
            Self.makeTerminalConfiguration(settings: cachedSettings, themeName: cachedThemeName)
        )
    }

    private func configure(workingDirectory: String?, settings: HarnessSettings?) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.delegate = self
        terminalView.controller = controller
        var options = TerminalSurfaceOptions(
            backend: .inMemory(memorySession),
            workingDirectory: workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
        if let settings {
            options.fontSize = settings.fontSize
        }
        terminalView.configuration = options
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    public func applyTheme(named name: String) {
        cachedThemeName = name
        appliedThemeBackgroundHex = ThemeManager.backgroundHex(themeName: name)
        pushConfiguration()
    }

    public func applySettings(_ settings: HarnessSettings) {
        cachedSettings = settings
        // Clear — libghostty's own `withBackgroundOpacity` paint IS the bg paint
        // in the terminal area, mirroring the chrome backdrop's single `bg ×
        // opacity` layer in other regions. Painting bg color here would compound
        // alpha with libghostty's paint and make terminal area read as more
        // opaque than the sidebar at any opacity < 1.
        layer?.backgroundColor = NSColor.clear.cgColor
        pushConfiguration()
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(memorySession),
            fontSize: settings.fontSize,
            workingDirectory: terminalView.configuration.workingDirectory,
            context: terminalView.configuration.context
        )
        terminalView.fitToSize()
    }

    public override func layout() {
        super.layout()
        terminalView.fitToSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window?.firstResponder !== terminalView {
            window?.makeFirstResponder(terminalView)
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
        window?.makeFirstResponder(terminalView)
        hostDelegate?.terminalHostDidChangeFocus(true, surfaceID: surfaceID)
    }

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
                memorySession.receive(text)
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
                    self?.memorySession.receive(data)
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
/// never a view — so it's safe to call from libghostty's input callback thread.
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

extension TerminalHostView:
    TerminalSurfaceTitleDelegate,
    TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceResizeDelegate,
    TerminalSurfaceCloseDelegate,
    TerminalSurfaceDesktopNotificationDelegate,
    TerminalSurfaceBellDelegate,
    TerminalSurfacePwdDelegate,
    TerminalSurfaceFocusDelegate
{
    public func terminalDidResize(_ size: TerminalGridMetrics) {
        // Ordered + off-main (a synchronous request here would block the UI thread
        // on a socket round-trip during live resize).
        io.resize(rows: size.rows, cols: size.columns)
    }

    public func terminalDidChangeTitle(_ title: String) {
        hostDelegate?.terminalHostDidChangeTitle(title, surfaceID: surfaceID)
    }

    public func terminalDidResize(columns _: Int, rows _: Int) {}

    public func terminalDidClose(processAlive _: Bool) {
        hostDelegate?.terminalHostDidClose(surfaceID: surfaceID)
    }

    public func terminalDidRequestDesktopNotification(title: String, body: String) {
        hostDelegate?.terminalHostDidRequestDesktopNotification(title: title, body: body, surfaceID: surfaceID)
    }

    public func terminalDidRingBell() {
        hostDelegate?.terminalHostDidRingBell(surfaceID: surfaceID)
    }

    public func terminalDidChangeWorkingDirectory(_ path: String) {
        hostDelegate?.terminalHostDidChangeWorkingDirectory(path, surfaceID: surfaceID)
    }

    public func terminalDidChangeFocus(_ focused: Bool) {
        hostDelegate?.terminalHostDidChangeFocus(focused, surfaceID: surfaceID)
    }
}
