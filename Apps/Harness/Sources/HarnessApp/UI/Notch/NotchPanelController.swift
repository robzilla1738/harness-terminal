import AppKit
import HarnessCore
import SwiftUI

@MainActor
final class NotchPanelController: NSObject {
    static let shared = NotchPanelController()

    private let model = AgentNotchViewModel()
    private var panel: NotchPanel?
    private var started = false
    /// Whether the panel is currently ordered in. Tracked so live snapshot updates can refresh
    /// the HUD's data *without* re-asserting the panel frame or z-order on every tick — that
    /// per-tick `setFrame` + `orderFrontRegardless` was interrupting the open/close animation and
    /// is what made the HUD feel glitchy. The panel is (re)positioned only when it actually needs
    /// to be: enable/disable, screen-parameter changes, and first show.
    private var isPanelVisible = false

    private override init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        observeNotifications()
        refreshVisibility()
    }

    /// Full path: refresh data, (re)build + position the panel, and match its visibility to the
    /// current enabled state. Geometry is recomputed here only — it depends on the screen, not on
    /// the session snapshot. Called on launch, on the Settings toggle, from the menu, and on
    /// screen-parameter changes.
    func refreshVisibility() {
        model.refreshFromCoordinator()
        guard isEnabled else {
            hidePanel()
            return
        }
        createPanelIfNeeded()
        updatePanelGeometry()
        showPanel()
    }

    func openFromMenu() {
        let coordinator = SessionCoordinator.shared
        if !coordinator.settings.notchVisibilityMode.isEnabled(for: coordinator.settings.experienceMode) {
            coordinator.settings.notchVisibilityMode = .on
            try? coordinator.settings.save()
        }
        refreshVisibility()
        model.open()
    }

    func closeFromMenu() {
        model.close()
    }

    private var isEnabled: Bool {
        SessionCoordinator.shared.settings.notchVisibilityMode
            .isEnabled(for: SessionCoordinator.shared.settings.experienceMode)
    }

    private func observeNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(snapshotChanged(_:)),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }
        let metrics = currentMetrics()
        model.updateGeometry(metrics)
        let panel = NotchPanel(contentRect: nsRect(metrics.panelFrame))
        panel.contentView = NSHostingView(rootView: AgentNotchRootView(model: model))
        self.panel = panel
    }

    private func updatePanelGeometry() {
        guard let panel else { return }
        let metrics = currentMetrics()
        model.updateGeometry(metrics)
        panel.setFrame(nsRect(metrics.panelFrame), display: true)
    }

    private func showPanel() {
        guard let panel, !isPanelVisible else { return }
        panel.orderFrontRegardless()
        isPanelVisible = true
    }

    private func hidePanel() {
        model.close()
        guard isPanelVisible else { return }
        panel?.orderOut(nil)
        isPanelVisible = false
    }

    /// Live data path: a session-snapshot tick only refreshes the HUD's rows/peeks, and only while
    /// it is on screen. The panel frame and z-order are deliberately left alone so an in-flight
    /// open/close animation is never interrupted. An enabled-state flip arrives via
    /// `refreshVisibility` (the Settings toggle calls it directly); we reconcile here defensively
    /// if the two ever diverge.
    private func refreshData() {
        if isEnabled != isPanelVisible {
            refreshVisibility()
            return
        }
        guard isPanelVisible else { return }
        model.refreshFromCoordinator()
    }

    @objc private func snapshotChanged(_ note: Notification) {
        refreshData()
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        refreshVisibility()
    }

    private func currentMetrics() -> NotchLayoutMetrics {
        (NSScreen.main ?? NSScreen.screens.first).map(NotchGeometry.metrics(for:)) ?? NotchGeometry.fallback
    }

    private func nsRect(_ rect: NotchRect) -> NSRect {
        NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
