import AppKit
import HarnessCore

/// Title row atop a comfortable pane: the program's mark, the pane's identity
/// (`~/Code/app › nvim`), and split-right / split-down buttons. Double-click zooms the
/// pane; right-click offers split, zoom, rename, and close.
@MainActor
final class PaneHeaderView: NSView {
    private let surfaceID: SurfaceID
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let splitRight = SoftIconButton(frame: .zero)
    private let splitDown = SoftIconButton(frame: .zero)
    private var agent: AgentKind?
    private var isFocused = false

    init(surfaceID: SurfaceID) {
        self.surfaceID = surfaceID
        super.init(frame: .zero)
        wantsLayer = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = HarnessDesign.Typography.paneHeader
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        HarnessDesign.prepareChromeLabel(titleLabel)

        for (button, symbol, label, action) in [
            (splitRight, "rectangle.split.2x1", "Split right", #selector(splitRightClicked)),
            (splitDown, "rectangle.split.1x2", "Split down", #selector(splitDownClicked)),
        ] {
            button.style = .glyph
            button.setSymbol(symbol, accessibilityDescription: label, pointSize: HarnessDesign.chromeIconPointSize, weight: .regular)
            button.toolTip = label
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(splitRight)
        addSubview(splitDown)
        let inset = HarnessDesign.Spacing.lg
        let button = HarnessDesign.paneHeaderButtonSize
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HarnessDesign.paneHeaderHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HarnessDesign.Spacing.md),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: splitRight.leadingAnchor, constant: -HarnessDesign.Spacing.md),
            splitDown.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.sm),
            splitDown.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitDown.widthAnchor.constraint(equalToConstant: button),
            splitDown.heightAnchor.constraint(equalToConstant: button),
            splitRight.trailingAnchor.constraint(equalTo: splitDown.leadingAnchor, constant: -HarnessDesign.Spacing.xxs),
            splitRight.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitRight.widthAnchor.constraint(equalToConstant: button),
            splitRight.heightAnchor.constraint(equalToConstant: button),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // The header sits in the title-bar drag band of a full-size-content window; clicks
    // here are for the pane, not for moving the window.
    override var mouseDownCanMoveWindow: Bool { false }

    func update(title: String, agent: AgentKind?, focused: Bool) {
        titleLabel.stringValue = title
        setAccessibilityLabel("Pane: \(title)")
        self.agent = agent
        isFocused = focused
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessChrome.current
        // The fill is the island's call (canvas color at the paint opacity); see PaneIslandView.
        titleLabel.textColor = isFocused ? c.textPrimary : c.textSecondary
        HarnessDesign.applyChromeLabelAppearance([titleLabel], isDark: c.isDark)
        if let agent {
            icon.image = AgentIconRenderer.templateOrMonogramImage(for: agent, size: 16)
            icon.contentTintColor = NSColor.fromHex(SessionCoordinator.shared.settings.agentColorHex(for: agent)) ?? c.accent
        } else {
            icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            icon.contentTintColor = c.textTertiary
        }
        splitRight.applyChrome()
        splitDown.applyChrome()
    }

    // MARK: - Actions

    private var coordinator: SessionCoordinator { .shared }

    /// Every header action targets this pane, so focus it first.
    private func focusPane() {
        coordinator.setActiveSurface(surfaceID)
        coordinator.terminalHostIfExists(for: surfaceID)?.focusTerminal()
    }

    @objc private func splitRightClicked() { split(.horizontal) }
    @objc private func splitDownClicked() { split(.vertical) }

    private func split(_ direction: SplitDirection) {
        focusPane()
        coordinator.splitActivePane(direction: direction)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            focusPane()
            coordinator.zoomActivePane()
        } else {
            focusPane()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        focusPane()
        let menu = NSMenu()
        for (title, action) in [
            ("Split Right", #selector(splitRightClicked)),
            ("Split Down", #selector(splitDownClicked)),
            ("Zoom Pane", #selector(zoomClicked)),
            ("Rename Tab…", #selector(renameClicked)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Pane", action: #selector(closeClicked), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func zoomClicked() { coordinator.zoomActivePane() }
    @objc private func renameClicked() { coordinator.beginRenameActiveTab() }
    @objc private func closeClicked() { coordinator.killPane(surfaceID: surfaceID) }
}
