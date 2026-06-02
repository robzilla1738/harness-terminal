import AppKit
import HarnessCore

/// Sidebar header bell. Shows a small red badge with the count of tabs in
/// `waiting` state. Click opens the notifications dropdown; `Cmd+Shift+U`
/// jumps straight to the first waiting tab. Updates live from `NotificationBus.snapshotChanged`.
@MainActor
final class NotificationBellButton: NSControl {
    private let iconView = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let badgeBackground = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private var waitingCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Circular soft-button chrome (set in applyChrome/layout) to match SoftIconButton.
        layer?.cornerCurve = .continuous
        // The badge sits at the top-right corner and pokes just past the circular
        // disc (`cornerRadius` 15 set in `applyChrome`). AppKit re-syncs the backing
        // layer's `masksToBounds` from `clipsToBounds` on every layout pass, so the
        // direct layer set alone gets overwritten and the badge is clipped to the
        // disc curve. Clear both so the badge always renders in full.
        clipsToBounds = false
        layer?.masksToBounds = false

        // Weight matches the rest of the header glyphs (workspace pill, chevron,
        // ellipsis) so the chrome icon set stays one uniform pack.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")?
            .withSymbolConfiguration(config)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        badgeBackground.wantsLayer = true
        badgeBackground.layer?.cornerRadius = 7
        badgeBackground.layer?.cornerCurve = .continuous
        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        badgeBackground.isHidden = true

        badge.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBackground.addSubview(badge)

        addSubview(iconView)
        addSubview(badgeBackground)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            badgeBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            badgeBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            badgeBackground.heightAnchor.constraint(equalToConstant: 14),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 14),

            badge.leadingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: 4),
            badge.trailingAnchor.constraint(equalTo: badgeBackground.trailingAnchor, constant: -4),
            badge.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),
        ])
        toolTip = "Notifications"
        applyChrome()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(refresh),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        applyChrome() // keep the circular corner radius correct once bounds are known
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let target, let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }

    @objc private func refresh() {
        let count = SessionCoordinator.shared.snapshot.workspaces.reduce(into: 0) { acc, ws in
            acc += ws.sessions.flatMap(\.tabs).filter { $0.status == .waiting }.count
        }
        waitingCount = count
        badge.stringValue = count > 99 ? "99+" : "\(count)"
        badgeBackground.isHidden = count == 0
        setAccessibilityLabel(count == 0 ? "Notifications" : "\(count) notifications")
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessDesign.chrome
        // Shared circular icon-button chrome — identical disc to `SoftIconButton` (the
        // sidebar toggle, footer gear/＋/palette, tab strip ＋) so the whole icon set
        // reads as one themed pack that follows the theme like the session cards.
        HarnessDesign.applyIconButtonChrome(to: layer, bounds: bounds, isHovered: isHovered)
        let hasUnread = waitingCount > 0
        // Theme accent (the cursor/foreground-derived hue), never a hardcoded blue, so the
        // bell follows the active theme like the rest of the chrome.
        iconView.contentTintColor = hasUnread ? c.accent : (isHovered ? c.textPrimary : c.textSecondary)
        badgeBackground.layer?.backgroundColor = c.danger.cgColor
        // SF Symbol variant: filled when there's an unread notification, outline
        // when idle. Makes the visual state read in a glance.
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let symbol = hasUnread ? "bell.fill" : "bell"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Notifications")?
            .withSymbolConfiguration(config)
    }
}
