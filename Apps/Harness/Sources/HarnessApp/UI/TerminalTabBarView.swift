import AppKit
import HarnessCore

@MainActor
protocol TerminalTabBarDelegate: AnyObject {
    func tabBarDidSelect(tabID: TabID)
    func tabBarDidRequestNewTab()
    func tabBarDidRequestClose(tabID: TabID)
}

extension TerminalTabBarDelegate {
    func tabBarDidRequestClose(tabID: TabID) {}
}

@MainActor
final class TerminalTabBarView: NSView {
    weak var delegate: TerminalTabBarDelegate?

    private let stack = NSStackView()
    private let newTabButton = SoftIconButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    private var tabs: [Tab] = []
    private var activeTabID: TabID?
    private var pillsByID: [TabID: TabPillView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        HarnessDesign.applyTabBarChrome(to: self)

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        let plusConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        newTabButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(plusConfig)
        newTabButton.imagePosition = .imageOnly
        newTabButton.toolTip = "New tab (⌘T)"
        newTabButton.target = self
        newTabButton.action = #selector(addNewTab)

        // The "+" lives at the end of the pill stack (Ghostty/Chrome style),
        // not pinned to the right edge.
        stack.addArrangedSubview(newTabButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            heightAnchor.constraint(equalToConstant: HarnessDesign.tabBarHeight),
        ])
    }

    func reload(tabs: [Tab], activeTabID: TabID?) {
        self.tabs = tabs
        self.activeTabID = activeTabID

        // Tear down everything except the trailing "+" button so we can re-build pills.
        for view in stack.arrangedSubviews where view !== newTabButton {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        pillsByID.removeAll(keepingCapacity: true)
        for tab in tabs {
            let pill = TabPillView(tab: tab, isActive: tab.id == activeTabID)
            pill.onSelect = { [weak self] id in self?.delegate?.tabBarDidSelect(tabID: id) }
            pill.onClose = { [weak self] id in self?.delegate?.tabBarDidRequestClose(tabID: id) }
            stack.insertArrangedSubview(pill, at: stack.arrangedSubviews.count - 1)
            pillsByID[tab.id] = pill
        }
        applyChrome()
    }

    /// Update titles/status of existing pills without rebuilding the tree, used
    /// when `metadataChanged` fires (live PWD / title / agent updates).
    func refreshMetadata(tabs: [Tab], activeTabID: TabID?) {
        // If the set of tabs changed structurally, fall back to a full reload.
        let currentIDs = Set(self.tabs.map(\.id))
        let newIDs = Set(tabs.map(\.id))
        if currentIDs != newIDs || self.tabs.count != tabs.count {
            reload(tabs: tabs, activeTabID: activeTabID)
            return
        }
        self.tabs = tabs
        self.activeTabID = activeTabID
        for tab in tabs {
            pillsByID[tab.id]?.update(tab: tab, isActive: tab.id == activeTabID)
        }
    }

    func applyChrome() {
        HarnessDesign.applyTabBarChrome(to: self)
        for case let pill as TabPillView in stack.arrangedSubviews {
            pill.applyChrome(isActive: pill.tabID == activeTabID)
        }
        newTabButton.applyChrome()
    }

    @objc private func addNewTab() {
        delegate?.tabBarDidRequestNewTab()
    }
}

@MainActor
private final class TabPillView: NSView {
    let tabID: TabID
    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let statusDot = StatusDotView()
    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isActive = false
    private var isHovered = false
    private var status: TabStatus = .idle
    private var currentAgent: AgentSnapshot?

    init(tab: Tab, isActive: Bool) {
        tabID = tab.id
        super.init(frame: .zero)
        self.isActive = isActive
        self.status = tab.status
        self.currentAgent = tab.agent

        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.pillCornerRadius
        layer?.cornerCurve = .continuous

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.stringValue = displayTitle(for: tab)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let xConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(xConfig)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .smallSquare
        closeButton.setButtonType(.momentaryChange)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 0
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 7
        closeButton.layer?.cornerCurve = .continuous

        addSubview(statusDot)
        addSubview(titleLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: HarnessDesign.tabPillHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            statusDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusDot.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        applyChrome(isActive: isActive)
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            closeButton.animator().alphaValue = 1
        }
        applyChrome(isActive: isActive)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            closeButton.animator().alphaValue = 0
        }
        applyChrome(isActive: isActive)
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        // Don't double-fire when the click was on the inner close button.
        if !closeButton.frame.contains(local), bounds.contains(local) {
            onSelect?(tabID)
        }
        super.mouseUp(with: event)
    }

    @objc private func closeClicked() {
        onClose?(tabID)
    }

    func update(tab: Tab, isActive: Bool) {
        status = tab.status
        currentAgent = tab.agent
        titleLabel.stringValue = displayTitle(for: tab)
        applyChrome(isActive: isActive)
    }

    private func displayTitle(for tab: Tab) -> String {
        let folder = (tab.cwd as NSString).lastPathComponent
        if !folder.isEmpty { return folder }
        let hasCustomTitle = !tab.title.isEmpty && tab.title != "Shell"
        if hasCustomTitle { return tab.title }
        return "Terminal"
    }

    func applyChrome(isActive: Bool) {
        self.isActive = isActive
        let c = HarnessDesign.chrome

        switch status {
        case .idle:
            if let agent = currentAgent, agent.activity == .working {
                statusDot.style = .agent(hex: agent.kind.dotHex)
            } else {
                statusDot.style = isActive ? .accent : .idle
            }
        case .waiting: statusDot.style = .waiting
        case .error: statusDot.style = .error
        }
        statusDot.applyStyle()

        if isActive {
            layer?.backgroundColor = c.surfaceElevated.cgColor
            titleLabel.textColor = c.textPrimary
        } else if isHovered {
            layer?.backgroundColor = c.rowHoverFill.cgColor
            titleLabel.textColor = c.textPrimary
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = c.textSecondary
        }

        closeButton.contentTintColor = c.textTertiary
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
