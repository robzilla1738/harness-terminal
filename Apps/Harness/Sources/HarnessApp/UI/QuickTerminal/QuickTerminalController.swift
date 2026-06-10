import AppKit
import HarnessCore
import HarnessTerminalKit

/// Owns the quick terminal: a Quake-style dropdown panel hosting a dedicated daemon-backed terminal
/// surface, summoned by a global hotkey. Mirrors `NotchPanelController`'s singleton lifecycle; the
/// surface is keyed by a fixed ID (see `surfaceID`) and reattached via `TerminalHostView`'s own
/// idempotent `.ensureSurface`, so one surface is reused for the app's lifetime.
@MainActor
final class QuickTerminalController: NSObject {
    static let shared = QuickTerminalController()

    private var panel: QuickTerminalPanel?
    private var host: TerminalHostView?
    private var started = false
    private lazy var hotkey = QuickTerminalHotkey { [weak self] in self?.toggle() }

    /// A fixed, reserved surface ID so the quick terminal reuses ONE daemon surface for the app's
    /// lifetime (and across launches) rather than minting a new one each time. The surface is never
    /// part of any tab layout, so a fresh-per-launch one would never be reaped — its PTY and
    /// scrollback file would accumulate. `TerminalHostView` issues an idempotent `.ensureSurface`
    /// for this ID itself (create-if-absent, reattach-if-present), so no explicit `createSurface`.
    private static let surfaceID = SurfaceID(uuidString: "00000000-0000-0000-0000-000000000021")!

    private override init() { super.init() }

    /// Install the global hotkey at launch (iff enabled). Idempotent.
    func start() {
        guard !started else { return }
        started = true
        rebuildFromSettings()
    }

    /// (Re)register or tear down the global hotkey to match settings. Safe to call on every settings
    /// change — the settings pane calls this alongside `PrefixKeymap.rebuildFromSettings()`.
    func rebuildFromSettings() {
        let settings = SessionCoordinator.shared.settings
        if settings.quickTerminalEnabled {
            hotkey.register(spec: settings.quickTerminalHotkey)
        } else {
            hotkey.unregister()
            hide()
        }
    }

    /// Show if hidden, hide if visible — the action the global hotkey fires.
    func toggle() {
        guard SessionCoordinator.shared.settings.quickTerminalEnabled else { return }
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        let panel = ensurePanel()
        panel.setFrame(Self.topFrame(for: NSScreen.main ?? NSScreen.screens.first), display: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        host?.focusTerminal()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    /// Create the panel + its dedicated surface on first use; reuse them thereafter. The host
    /// constructs (or reattaches to) the fixed-ID daemon surface itself, so this never fails — if
    /// the daemon is still starting, the host shows a reconnecting state and recovers.
    private func ensurePanel() -> QuickTerminalPanel {
        if let panel { return panel }
        let coordinator = SessionCoordinator.shared
        let cwd = coordinator.settings.defaultCWD
        let host = coordinator.terminalHost(for: Self.surfaceID, cwd: cwd)
        self.host = host

        let frame = Self.topFrame(for: NSScreen.main ?? NSScreen.screens.first)
        let panel = QuickTerminalPanel(contentRect: frame)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        self.panel = panel
        return panel
    }

    /// A dropdown band spanning the top ~40% of the screen's visible area (below the menu bar).
    private static func topFrame(for screen: NSScreen?) -> NSRect {
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let height = (vf.height * 0.4).rounded()
        return NSRect(x: vf.minX, y: vf.maxY - height, width: vf.width, height: height)
    }
}
