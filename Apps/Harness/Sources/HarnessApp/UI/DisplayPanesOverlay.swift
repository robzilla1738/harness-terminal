import AppKit
import HarnessCore
import HarnessTerminalKit

/// `display-panes`: briefly overlays a big number on each pane in the active tab.
/// Press the matching digit to jump to that pane (Esc / any other key dismisses).
/// A single app-wide key monitor captures the choice, mirroring tmux.
@MainActor
final class DisplayPanesOverlay {
    static let shared = DisplayPanesOverlay()
    private init() {}

    private var labels: [NSView] = []
    private var monitor: Any?
    private var targets: [Int: SurfaceID] = [:]
    private var onSelect: ((SurfaceID) -> Void)?

    func show(panes: [(number: Int, host: TerminalHostView)], onSelect: @escaping (SurfaceID) -> Void) {
        dismiss()
        guard panes.count > 1, let contentView = panes.first?.host.window?.contentView else { return }
        self.onSelect = onSelect
        for (number, host) in panes {
            targets[number] = host.surfaceID
            let frameInContent = host.convert(host.bounds, to: contentView)
            let chip = makeChip(number)
            let size: CGFloat = 72
            chip.frame = NSRect(
                x: frameInContent.midX - size / 2,
                y: frameInContent.midY - size / 2,
                width: size,
                height: size
            )
            contentView.addSubview(chip)
            labels.append(chip)
        }
        // Auto-dismiss after a few seconds if the user doesn't choose.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.dismiss() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // consume the keystroke
        }
    }

    private func handle(_ event: NSEvent) {
        defer { dismiss() }
        guard let chars = event.charactersIgnoringModifiers,
              let number = Int(chars),
              let surfaceID = targets[number]
        else { return }
        onSelect?(surfaceID)
    }

    func dismiss() {
        for label in labels { label.removeFromSuperview() }
        labels.removeAll()
        targets.removeAll()
        onSelect = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func makeChip(_ number: Int) -> NSView {
        let chrome = HarnessChrome.current
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = chrome.accent.withAlphaComponent(0.92).cgColor
        view.layer?.borderWidth = 1
        view.layer?.borderColor = chrome.terminalBackground.withAlphaComponent(0.5).cgColor

        let label = NSTextField(labelWithString: "\(number)")
        label.font = .monospacedDigitSystemFont(ofSize: 38, weight: .bold)
        label.textColor = chrome.terminalBackground
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }
}
