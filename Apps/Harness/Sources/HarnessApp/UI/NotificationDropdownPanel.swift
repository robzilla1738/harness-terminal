import AppKit
import HarnessCore

/// Popover-style panel that the notification bell shows. Lists every tab in
/// `.waiting` state with its agent and a short body; clicking a row jumps to
/// that pane and clears the notification.
@MainActor
final class NotificationDropdownPanelView: NSView {
    private let entries: [NotificationEntry]
    private let onSelect: (NotificationEntry) -> Void
    private let onClearAll: () -> Void
    let preferredHeight: CGFloat

    init(
        entries: [NotificationEntry],
        onSelect: @escaping (NotificationEntry) -> Void,
        onClearAll: @escaping () -> Void
    ) {
        self.entries = entries
        self.onSelect = onSelect
        self.onClearAll = onClearAll
        // Header (28) + rows (52 each, max 6 shown then scrolls) + footer (38).
        let visibleRowCount = min(entries.count, 6)
        let bodyHeight = entries.isEmpty ? 64 : CGFloat(visibleRowCount * 52 + 10)
        self.preferredHeight = 28 + bodyHeight + 38
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        let c = HarnessDesign.chrome
        layer?.backgroundColor = (c.terminalBackground.blended(withFraction: c.isDark ? 0.06 : 0.04, of: c.textPrimary) ?? c.sidebarBackground).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.11 : 0.14).cgColor
        HarnessDesign.applyShadow(.overlay, to: layer)

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupContent() {
        let header = NSTextField(labelWithString: "Notifications")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = HarnessDesign.chrome.textTertiary
        header.translatesAutoresizingMaskIntoConstraints = false

        let bodyContainer = NSView()
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "You're all caught up.")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = HarnessDesign.chrome.textSecondary
            empty.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: bodyContainer.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: bodyContainer.centerYAnchor),
            ])
        } else {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .width
            stack.spacing = 2
            stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
            stack.translatesAutoresizingMaskIntoConstraints = false
            for entry in entries {
                let row = NotificationRowView(entry: entry)
                row.onClick = { [onSelect, weak self] in
                    onSelect(entry)
                    self?.window?.close()
                }
                stack.addArrangedSubview(row)
            }
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.scrollerStyle = .overlay
            scroll.documentView = stack
            scroll.translatesAutoresizingMaskIntoConstraints = false
            bodyContainer.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
                stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            ])
        }

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let clearAll = NSButton(title: "Clear all", target: self, action: #selector(clearAllClicked))
        clearAll.bezelStyle = .accessoryBarAction
        clearAll.isBordered = false
        clearAll.contentTintColor = HarnessDesign.chrome.textSecondary
        clearAll.font = .systemFont(ofSize: 11.5, weight: .medium)
        clearAll.isEnabled = !entries.isEmpty
        clearAll.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(clearAll)

        addSubview(header)
        addSubview(bodyContainer)
        addSubview(footer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            header.heightAnchor.constraint(equalToConstant: 20),

            bodyContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32),
            clearAll.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -10),
            clearAll.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    @objc private func clearAllClicked() {
        onClearAll()
        window?.close()
    }
}

@MainActor
private final class NotificationRowView: NSView {
    var onClick: (() -> Void)?

    private let entry: NotificationEntry
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }

    init(entry: NotificationEntry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 50).isActive = true

        let coordinator = SessionCoordinator.shared

        let dot = StatusDotView()
        if let kind = entry.agentKind {
            dot.style = .agent(hex: coordinator.settings.agentColorHex(for: kind))
        } else {
            dot.style = .waiting
        }
        dot.applyStyle()
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: entry.tabTitle)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = HarnessDesign.chrome.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let agentLabel = entry.agentKind?.displayName ?? "Agent"
        let bodyLabel = NSTextField(labelWithString: "\(agentLabel) · \(entry.body)")
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = HarnessDesign.chrome.textTertiary
        bodyLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView(views: [title, bodyLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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
        if bounds.contains(point) { onClick?() }
    }

    private func applyChrome() {
        let c = HarnessDesign.chrome
        layer?.backgroundColor = isHovered
            ? c.textPrimary.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
    }
}
