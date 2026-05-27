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
    private var outputSubscription: DaemonSubscription?
    private var isWaiting = false
    private var isActiveBorder = false

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
        let writeSurfaceID = surfaceEnv
        self.memorySession = InMemoryTerminalSession(
            write: { data in
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = try? DaemonClient().request(.sendData(surfaceID: writeSurfaceID, data: data))
                }
            },
            resize: { viewport in
                DispatchQueue.global(qos: .utility).async {
                    _ = try? DaemonClient().request(.resizeSurface(
                        surfaceID: writeSurfaceID,
                        rows: viewport.rows,
                        cols: viewport.columns
                    ))
                }
            }
        )
        self.controller = controller ?? TerminalController {
            // Let Ghostty inject its shell-integration script when possible.
            // When the integration runs, the shell emits OSC 7 + OSC 133 so
            // libghostty can deliver real-time pwd/exit-code updates. The
            // PID-based SurfaceShellTracker is the fallback.
            $0.withCustom("shell-integration", "detect")
            $0.withCustom("shell-integration-features", "cursor,sudo,title")
            if let settings {
                $0.withFontSize(settings.fontSize)
                $0.withFontFamily(settings.fontFamily)
                $0.withBackgroundOpacity(Double(settings.backgroundOpacity))
                $0.withBackgroundBlur(settings.backgroundBlur)
                $0.withWindowPaddingX(Int(settings.windowPaddingX.rounded()))
                $0.withWindowPaddingY(Int(settings.windowPaddingY.rounded()))
                if let bg = settings.customBackgroundHex { $0.withBackground(bg) }
                if let fg = settings.customForegroundHex { $0.withForeground(fg) }
                if let cursor = settings.customCursorHex { $0.withCursorColor(cursor) }
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
        if let bg = settings?.customBackgroundHex, let color = NSColor.fromHex(bg) {
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
        ThemeManager.apply(themeName: name, to: controller)
    }

    public func applySettings(_ settings: HarnessSettings) {
        if let bg = settings.customBackgroundHex, let color = NSColor.fromHex(bg) {
            layer?.backgroundColor = color.withAlphaComponent(CGFloat(settings.backgroundOpacity)).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
        _ = controller.setTerminalConfiguration(
            TerminalConfiguration(startingFrom: controller.terminalConfiguration) {
                $0.withFontSize(settings.fontSize)
                $0.withFontFamily(settings.fontFamily)
                $0.withBackgroundOpacity(Double(settings.backgroundOpacity))
                $0.withBackgroundBlur(settings.backgroundBlur)
                $0.withWindowPaddingX(Int(settings.windowPaddingX.rounded()))
                $0.withWindowPaddingY(Int(settings.windowPaddingY.rounded()))
                if let bg = settings.customBackgroundHex { $0.withBackground(bg) }
                if let fg = settings.customForegroundHex { $0.withForeground(fg) }
                if let cursor = settings.customCursorHex { $0.withCursorColor(cursor) }
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
        let ringRect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: ringRect, xRadius: 6, yRadius: 6)
        if isWaiting {
            NSColor.systemBlue.withAlphaComponent(0.85).setStroke()
            path.lineWidth = 3
            path.stroke()
        } else if isActiveBorder {
            NSColor.white.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 2
            path.stroke()
        }
    }

    public func focusTerminal() {
        window?.makeFirstResponder(terminalView)
        hostDelegate?.terminalHostDidChangeFocus(true, surfaceID: surfaceID)
    }

    private func ensureDaemonSurface(cwd: String?, shell: String, settings: HarnessSettings?) {
        _ = try? daemonClient.request(.ensureSurface(
            surfaceID: surfaceID.uuidString,
            cwd: cwd ?? FileManager.default.homeDirectoryForCurrentUser.path,
            shell: shell,
            rows: 24,
            cols: 80,
            scrollbackBytes: (settings?.scrollbackLines ?? 10_000) * 160
        ))
    }

    private func startDaemonOutput() {
        if case let .text(text) = try? daemonClient.request(.replayScrollback(
            surfaceID: surfaceID.uuidString,
            fromSequence: nil
        )), !text.isEmpty {
            memorySession.receive(text)
        }
        outputSubscription = try? daemonClient.subscribeSurfaceOutput(surfaceID: surfaceID.uuidString) { [weak self] data, _ in
            Task { @MainActor in
                self?.memorySession.receive(data)
            }
        }
    }

    deinit {
        outputSubscription?.cancel()
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
        _ = try? daemonClient.request(.resizeSurface(
            surfaceID: surfaceID.uuidString,
            rows: size.rows,
            cols: size.columns
        ))
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
