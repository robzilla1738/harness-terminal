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
    private var outputSubscription: DaemonSubscription?
    private var isWaiting = false
    private var isActiveBorder = false
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
            isActiveBorder = newValue
            needsDisplay = true
        }
    }

    public init(
        surfaceID: SurfaceID = UUID(),
        workingDirectory: String? = nil,
        harnessSurfaceEnv: String? = nil,
        settings: HarnessSettings? = nil,
        controller: TerminalController? = nil
    ) {
        self.surfaceID = surfaceID
        let shell = settings?.defaultShell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let surfaceEnv = harnessSurfaceEnv ?? surfaceID.uuidString
        let io = SurfaceIO(surfaceID: surfaceEnv)
        self.io = io
        self.memorySession = InMemoryTerminalSession(
            write: { data in io.send(data) },
            resize: { viewport in io.resize(rows: viewport.rows, cols: viewport.columns) }
        )
        self.controller = controller ?? Self.makeController(settings: settings)
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

    private static let emptyControllerTheme = TerminalTheme(light: .init(), dark: .init())

    private static func makeController(settings: HarnessSettings?) -> TerminalController {
        TerminalController(
            configuration: makeTerminalConfiguration(settings: settings),
            theme: emptyControllerTheme
        )
    }

    static func makeTerminalConfiguration(settings: HarnessSettings?) -> TerminalConfiguration {
        TerminalConfiguration {
            configureTerminalBuilder(&$0, settings: settings)
        }
    }

    private static func configureTerminalBuilder(
        _ builder: inout TerminalConfiguration.Builder,
        settings: HarnessSettings?
    ) {
        builder.withCustom("shell-integration", "detect")
        builder.withCustom("shell-integration-features", "sudo,title")
        TerminalColorPipeline.apply(to: &builder)

        guard let settings else { return }
        builder.withFontSize(settings.fontSize)
        builder.withFontFamily(settings.fontFamily)
        builder.withBackgroundOpacity(Double(settings.backgroundOpacity))
        builder.withBackgroundBlur(settings.backgroundBlur)
        builder.withWindowPaddingX(Int(settings.windowPaddingX.rounded()))
        builder.withWindowPaddingY(Int(settings.windowPaddingY.rounded()))
        let background = settings.customBackgroundHex ?? ThemeManager.defaultBaselineBackgroundHex
        let foreground = settings.customForegroundHex ?? ThemeManager.defaultBaselineForegroundHex
        builder.withBackground(background)
        builder.withForeground(foreground)
        builder.withCursorColor(settings.customCursorHex ?? foreground)
        builder.withCursorStyle(TerminalCursorStyle(rawValue: settings.cursorStyle) ?? .block)
        builder.withCursorStyleBlink(settings.cursorBlink)
        builder.withCustom("copy-on-select", settings.copyOnSelect ? "true" : "false")
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
        // Harness themes style chrome. Terminal surfaces intentionally keep an
        // empty controller theme so ANSI/truecolor output from TUIs is not retinted.
    }

    public func applySettings(_ settings: HarnessSettings) {
        layer?.backgroundColor = NSColor.clear.cgColor
        _ = controller.setTerminalConfiguration(
            Self.makeTerminalConfiguration(settings: settings)
        )
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
            outputSubscription = try daemonClient.subscribeSurfaceOutput(surfaceID: surfaceID.uuidString) { [weak self] data, _ in
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
