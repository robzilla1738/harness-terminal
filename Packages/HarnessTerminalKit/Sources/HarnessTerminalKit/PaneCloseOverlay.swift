import AppKit

/// Hover-reveal pane close affordance (#168): a small ×, top-right of the pane, visible only
/// while the pointer is inside its corner region — invisible at rest, honoring the no-pane-chrome
/// rule (the tab dot is the only persistent indicator by design). The host shows it only when
/// the tab has more than one pane (a single-pane tab already has the tab's close button) and
/// routes the click through the same close-pane command path as `prefix x`.
final class PaneCloseOverlay: NSView {
    /// Fired on click. The host forwards to the app, which resolves this pane's `PaneID` and
    /// issues the regular kill-pane command — no separate close path.
    var onClose: (() -> Void)?

    /// The hover region pinned to the pane's top-right corner that reveals the button — a
    /// forgiving target so the × (small by design) doesn't demand pixel hunting.
    static let hoverRegionSize = NSSize(width: 56, height: 40)
    private static let buttonInset: CGFloat = 8
    private static let buttonSize: CGFloat = 18
    private static let fadeDuration: TimeInterval = 0.15

    private let button = NSButton()
    private(set) var isRevealed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .shadowlessSquare
        button.imageScaling = .scaleProportionallyUpOrDown
        button.image = NSImage(
            systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close Pane"
        )
        button.target = self
        button.action = #selector(closeClicked)
        button.setAccessibilityLabel("Close Pane")
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor, constant: Self.buttonInset),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.buttonInset),
            button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
            button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
        ])
        // Invisible at rest; `setRevealed` fades it in only while the corner is hovered.
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Tint to the canvas foreground so the × stays legible on any theme, like the other overlays.
    func applyColor(_ color: NSColor) {
        button.contentTintColor = color.withAlphaComponent(0.55)
    }

    func setRevealed(_ revealed: Bool, animated: Bool = true) {
        guard revealed != isRevealed else { return }
        isRevealed = revealed
        if revealed { isHidden = false }
        guard animated else {
            alphaValue = revealed ? 1 : 0
            isHidden = !revealed
            return
        }
        NSAnimationContext.runAnimationGroup({ [weak self] context in
            context.duration = Self.fadeDuration
            self?.animator().alphaValue = revealed ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isRevealed else { return }
            self.isHidden = true
        })
    }

    /// Only the button is clickable — the rest of the hover region passes clicks (and the
    /// hidden state passes everything) through to the terminal beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isRevealed else { return nil }
        let result = super.hitTest(point)
        return result === button || result?.isDescendant(of: button) == true ? result : nil
    }

    @objc private func closeClicked() {
        onClose?()
    }
}
