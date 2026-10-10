import AppKit
import HarnessCore

/// Title row atop a comfortable pane: the program's mark, the pane's identity
/// (`~/Code/app › nvim`), and split-right / split-down buttons. Double-click zooms the
/// pane; right-click offers split, zoom, rename, and close.
@MainActor
final class PaneHeaderView: NSView, NSDraggingSource {
    private let surfaceID: SurfaceID
    private let icon = NSImageView()
    private let agentIcon = NSImageView()
    private var agentIconWidth: NSLayoutConstraint!
    private var titleLeading: NSLayoutConstraint!
    private let titleLabel = NSTextField(labelWithString: "")
    private let splitRight = SoftIconButton(frame: .zero)
    private let splitDown = SoftIconButton(frame: .zero)
    /// "Viewing at 120×40 · Take", when another client owns this pane's size.
    private let viewing = NSButton(title: "", target: nil, action: nil)
    private var ownership: SizeOwnership?
    private var agent: AgentKind?
    private var isFocused = false

    init(surfaceID: SurfaceID) {
        self.surfaceID = surfaceID
        super.init(frame: .zero)
        wantsLayer = true

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        icon.setAccessibilityElement(false)
        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        agentIcon.translatesAutoresizingMaskIntoConstraints = false
        agentIcon.setAccessibilityElement(false)

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
            button.setSymbol(symbol, accessibilityDescription: label, pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
            button.toolTip = label
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
        }

        viewing.isBordered = false
        viewing.font = HarnessDesign.Typography.paneHeader
        viewing.target = self
        viewing.action = #selector(takeClicked)
        viewing.toolTip = "Another window or attached terminal sets this pane's size. Click to size it to this window."
        viewing.isHidden = true
        viewing.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(agentIcon)
        addSubview(titleLabel)
        addSubview(viewing)
        addSubview(splitRight)
        addSubview(splitDown)
        let inset = HarnessDesign.Spacing.lg
        let button = HarnessDesign.paneHeaderButtonSize
        agentIconWidth = agentIcon.widthAnchor.constraint(equalToConstant: 0)
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: agentIcon.trailingAnchor)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HarnessDesign.paneHeaderHeight),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 14),
            agentIcon.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HarnessDesign.Spacing.md),
            agentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            agentIconWidth,
            agentIcon.heightAnchor.constraint(equalToConstant: HarnessDesign.paneHeaderIconSize),
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: viewing.leadingAnchor, constant: -HarnessDesign.Spacing.md),
            viewing.trailingAnchor.constraint(equalTo: splitRight.leadingAnchor, constant: -HarnessDesign.Spacing.md),
            viewing.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitDown.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.md),
            splitDown.centerYAnchor.constraint(equalTo: centerYAnchor),
            splitDown.widthAnchor.constraint(equalToConstant: button),
            splitDown.heightAnchor.constraint(equalToConstant: button),
            splitRight.trailingAnchor.constraint(equalTo: splitDown.leadingAnchor, constant: -HarnessDesign.Spacing.xs),
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

    func update(title: String, agent: AgentKind?, focused: Bool, ownership: SizeOwnership? = nil) {
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        setAccessibilityLabel("Pane: \(title)")
        self.agent = agent
        self.ownership = ownership
        isFocused = focused
        applyChrome()
    }

    private var viewsAnotherClientsSize: Bool { ownership.map { !$0.owner } ?? false }

    func applyChrome() {
        let c = HarnessChrome.current
        // The fill is the island's call (canvas color at the paint opacity); see PaneIslandView.
        titleLabel.textColor = isFocused ? c.textPrimary : c.textSecondary
        HarnessDesign.applyChromeLabelAppearance([titleLabel], isDark: c.isDark)
        icon.contentTintColor = isFocused ? c.textSecondary : c.textTertiary
        agentIcon.isHidden = agent == nil
        agentIconWidth.constant = agent == nil ? 0 : HarnessDesign.paneHeaderIconSize
        titleLeading.constant = agent == nil ? 0 : HarnessDesign.Spacing.md
        if let agent {
            agentIcon.image = AgentIconRenderer.templateOrMonogramImage(for: agent, size: HarnessDesign.paneHeaderIconSize)
            agentIcon.contentTintColor = c.textPrimary
        } else {
            agentIcon.image = nil
        }
        splitRight.applyChrome()
        splitDown.applyChrome()
        viewing.isHidden = !viewsAnotherClientsSize
        if let ownership, viewsAnotherClientsSize {
            viewing.attributedTitle = NSAttributedString(
                string: "Viewing at \(ownership.cols)×\(ownership.rows) · Take",
                attributes: [.font: HarnessDesign.Typography.paneHeader, .foregroundColor: c.accent]
            )
        }
    }

    override func layout() {
        super.layout()
        HarnessDesign.alignChromeText([titleLabel], in: self)
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
        dragOrigin = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            focusPane()
            coordinator.zoomActivePane()
        } else {
            focusPane()
        }
    }

    // MARK: - Dragging the pane

    private var dragOrigin: NSPoint?

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - origin.x, point.y - origin.y) > 4 else { return }
        dragOrigin = nil
        let item = NSDraggingItem(pasteboardWriter: PaneDrag.item(for: surfaceID))
        item.setDraggingFrame(bounds, contents: snapshotImage())
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    private func snapshotImage() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
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
        let watch = NSMenuItem(title: "Copy Watch Command", action: #selector(copyWatchClicked), keyEquivalent: "")
        watch.target = self
        watch.toolTip = "A harness-cli attach --read-only line for watching this pane from another terminal"
        menu.addItem(watch)
        if viewsAnotherClientsSize {
            let take = NSMenuItem(title: "Take Size", action: #selector(takeClicked), keyEquivalent: "")
            take.target = self
            menu.addItem(take)
        }
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Pane", action: #selector(closeClicked), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    @objc private func zoomClicked() { coordinator.zoomActivePane() }
    @objc private func copyWatchClicked() { coordinator.copyWatchCommand(for: surfaceID) }
    @objc private func takeClicked() { coordinator.terminalHostIfExists(for: surfaceID)?.takeSize() }
    @objc private func renameClicked() { coordinator.beginRenameActiveTab() }
    @objc private func closeClicked() { coordinator.killPane(surfaceID: surfaceID) }
}
