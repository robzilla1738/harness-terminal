import AppKit
import HarnessCore

/// Unread per-pane activity across attached hosts. Opens the attention view; reading an
/// alert clears its badge without resolving the program's blocked state.
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
        let config = NSImage.SymbolConfiguration(pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        iconView.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")?
            .withSymbolConfiguration(config)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter

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
            iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.58),
            iconView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.58),

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
        applyChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .enabledDuringMouseDrag, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        isHovered = HarnessDesign.pointerIsInside(self)
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        defer { isHovered = HarnessDesign.pointerIsInside(self) }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let target, let action {
            _ = NSApp.sendAction(action, to: target, from: self)
        }
    }

    @objc private func refresh() {
        let count = SessionCoordinator.shared.attentionList().filter {
            $0.entry.activity.unread && $0.entry.activity.rank >= .done
        }.count
        waitingCount = count
        badge.stringValue = count > 99 ? "99+" : "\(count)"
        badgeBackground.isHidden = count == 0
        setAccessibilityLabel(count == 0 ? "Notifications" : "\(count) notifications")
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessDesign.chrome
        // Same plain glyph as the tab-strip icons. No disc.
        HarnessDesign.applyGlyphButtonChrome(to: layer, bounds: bounds, isHovered: isHovered)
        // Re-clear clipping every pass: AppKit re-syncs `masksToBounds` from `clipsToBounds`
        // during layout (which calls this), and the circular `cornerRadius` would otherwise
        // shear off the badge's top-right corner where it pokes past the disc. The init-only
        // set isn't enough — it gets overwritten before the badge is ever shown.
        clipsToBounds = false
        layer?.masksToBounds = false
        let hasUnread = waitingCount > 0
        // Theme accent (the cursor/foreground-derived hue), never a hardcoded blue, so the
        // bell follows the active theme like the rest of the chrome.
        iconView.contentTintColor = hasUnread ? c.accent : (isHovered ? c.textPrimary : c.textSecondary)
        badgeBackground.layer?.backgroundColor = c.danger.cgColor
        // SF Symbol variant: filled when there's an unread notification, outline
        // when idle. Makes the visual state read in a glance.
        let config = NSImage.SymbolConfiguration(pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        let symbol = hasUnread ? "bell.fill" : "bell"
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Notifications")?
            .withSymbolConfiguration(config)
    }
}
