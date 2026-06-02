import AppKit
import HarnessCore
import SwiftUI

@MainActor
final class NotchPanelController: NSObject {
    static let shared = NotchPanelController()

    private let model = AgentNotchViewModel()
    private var panel: NotchPanel?
    private var started = false

    private override init() {
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        model.refreshFromCoordinator()
        observeNotifications()
        refreshVisibility()
    }

    func refreshVisibility() {
        model.refreshFromCoordinator()
        guard SessionCoordinator.shared.settings.notchVisibilityMode
            .isEnabled(for: SessionCoordinator.shared.settings.experienceMode)
        else {
            model.close()
            panel?.orderOut(nil)
            return
        }
        createPanelIfNeeded()
        updatePanelGeometry()
        panel?.orderFrontRegardless()
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
        let metrics = (NSScreen.main ?? NSScreen.screens.first).map(NotchGeometry.metrics(for:)) ?? NotchGeometry.fallback
        model.updateGeometry(metrics)
        let frame = nsRect(metrics.panelFrame)
        let panel = NotchPanel(contentRect: frame)
        panel.contentView = NSHostingView(rootView: AgentNotchRootView(model: model))
        self.panel = panel
    }

    private func updatePanelGeometry() {
        guard let panel,
              let screen = NSScreen.main ?? NSScreen.screens.first
        else { return }
        let metrics = NotchGeometry.metrics(for: screen)
        model.updateGeometry(metrics)
        panel.setFrame(nsRect(metrics.panelFrame), display: true)
    }

    @objc private func snapshotChanged(_ note: Notification) {
        refreshVisibility()
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        refreshVisibility()
    }

    private func nsRect(_ rect: NotchRect) -> NSRect {
        NSRect(
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height
        )
    }
}
