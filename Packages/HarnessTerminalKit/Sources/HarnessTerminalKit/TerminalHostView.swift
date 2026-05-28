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
    private var appliedThemeBackgroundHex: String?
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
        self.controller = controller ?? TerminalController {
            // Let Ghostty inject its shell-integration script when possible.
            // When the integration runs, the shell emits OSC 7 + OSC 133 so
            // libghostty can deliver real-time pwd/exit-code updates. The
            // PID-based SurfaceShellTracker is the fallback.
            $0.withCustom("shell-integration", "detect")
            $0.withCustom("shell-integration-features", "sudo,title")
            if let settings {
                $0.withFontSize(settings.fontSize)
                $0.withFontFamily(settings.fontFamily)
                $0.withBackgroundOpacity(Double(settings.backgroundOpacity))
                $0.withBackgroundBlur(settings.backgroundBlur)
                $0.withWindowPaddingX(Int(settings.windowPaddingX.rounded()))
                $0.withWindowPaddingY(Int(settings.windowPaddingY.rounded()))
                if settings.useCustomColors, let bg = settings.customBackgroundHex { $0.withBackground(bg) }
                if settings.useCustomColors, let fg = settings.customForegroundHex { $0.withForeground(fg) }
                if settings.useCustomColors, let cursor = settings.customCursorHex { $0.withCursorColor(cursor) }
                if settings.useCustomColors, let selection = settings.selectionBackgroundHex { $0.withSelectionBackground(selection) }
                if settings.useCustomColors, let selectionFg = settings.selectionForegroundHex { $0.withSelectionForeground(selectionFg) }
                if settings.useCustomColors, let bold = settings.boldColorHex { $0.withBoldColor(bold) }
                if settings.useCustomColors, let cursorText = settings.cursorTextHex { $0.withCursorText(cursorText) }
                if settings.minimumContrast > 1 { $0.withMinimumContrast(settings.minimumContrast) }
                if settings.useCustomColors {
                    for (paletteIndex, paletteColor) in settings.paletteHex.enumerated() {
                        if let paletteColor { $0.withPalette(paletteIndex, color: paletteColor) }
                    }
                }
                $0.withCursorStyle(TerminalCursorStyle(rawValue: settings.cursorStyle) ?? .block)
                $0.withCursorStyleBlink(settings.cursorBlink)
                $0.withCustom("copy-on-select", settings.copyOnSelect ? "true" : "false")
            }
        }
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

    private func configure(workingDirectory: String?, settings: HarnessSettings?) {
        wantsLayer = true
        if settings?.useCustomColors == true, let bg = settings?.customBackgroundHex, let color = NSColor.fromHex(bg) {
            layer?.backgroundColor = color.withAlphaComponent(CGFloat(settings?.backgroundOpacity ?? 1)).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
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
        appliedThemeBackgroundHex = ThemeManager.backgroundHex(themeName: name)
        ThemeManager.apply(themeName: name, to: controller)
    }

    public func applySettings(_ settings: HarnessSettings) {
        if settings.useCustomColors, let bg = settings.customBackgroundHex, let color = NSColor.fromHex(bg) {
            layer?.backgroundColor = color.withAlphaComponent(CGFloat(settings.backgroundOpacity)).cgColor
        } else if let bg = appliedThemeBackgroundHex, let color = NSColor.fromHex(bg) {
            layer?.backgroundColor = color.withAlphaComponent(CGFloat(settings.backgroundOpacity)).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        // CRITICAL: build a FRESH TerminalConfiguration every time instead of
        // `startingFrom: controller.terminalConfiguration`. The builder appends
        // commands without ever removing them, so once a user set
        // `customBackgroundHex = "#000000"` the `.background("#000000")` command
        // stuck in the per-session config forever — even after they cleared the
        // override or switched themes. The theme's own background could never
        // win because the per-session override always overlays it. Starting
        // fresh means: if `useCustomColors == false`, no color commands are
        // present and the theme's colors come through cleanly.
        _ = controller.setTerminalConfiguration(
            TerminalConfiguration {
                $0.withCustom("shell-integration", "detect")
                $0.withCustom("shell-integration-features", "sudo,title")
                $0.withFontSize(settings.fontSize)
                $0.withFontFamily(settings.fontFamily)
                $0.withBackgroundOpacity(Double(settings.backgroundOpacity))
                $0.withBackgroundBlur(settings.backgroundBlur)
                $0.withWindowPaddingX(Int(settings.windowPaddingX.rounded()))
                $0.withWindowPaddingY(Int(settings.windowPaddingY.rounded()))
                if settings.useCustomColors, let bg = settings.customBackgroundHex { $0.withBackground(bg) }
                if settings.useCustomColors, let fg = settings.customForegroundHex { $0.withForeground(fg) }
                if settings.useCustomColors, let cursor = settings.customCursorHex { $0.withCursorColor(cursor) }
                if settings.useCustomColors, let selection = settings.selectionBackgroundHex { $0.withSelectionBackground(selection) }
                if settings.useCustomColors, let selectionFg = settings.selectionForegroundHex { $0.withSelectionForeground(selectionFg) }
                if settings.useCustomColors, let bold = settings.boldColorHex { $0.withBoldColor(bold) }
                if settings.useCustomColors, let cursorText = settings.cursorTextHex { $0.withCursorText(cursorText) }
                if settings.minimumContrast > 1 { $0.withMinimumContrast(settings.minimumContrast) }
                if settings.useCustomColors {
                    for (paletteIndex, paletteColor) in settings.paletteHex.enumerated() {
                        if let paletteColor { $0.withPalette(paletteIndex, color: paletteColor) }
                    }
                }
                $0.withCursorStyle(TerminalCursorStyle(rawValue: settings.cursorStyle) ?? .block)
                $0.withCursorStyleBlink(settings.cursorBlink)
                $0.withCustom("copy-on-select", settings.copyOnSelect ? "true" : "false")
            }
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

private extension NSColor {
    static func fromHex(_ raw: String) -> NSColor? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
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
