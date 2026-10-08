import AppKit
import HarnessCore

@MainActor
protocol TerminalTabBarDelegate: AnyObject {
    func tabBarDidSelect(tabID: TabID)
    func tabBarDidRequestNewTab()
    func tabBarDidRequestClose(tabID: TabID)
    func tabBarDidReorder(tabID: TabID, toIndex: Int)
    func tabBarDidRequestCloseOthers(tabID: TabID)
    func tabBarDidRequestRename(tabID: TabID)
    func tabBarDidRequestSplit(tabID: TabID, direction: SplitDirection)
    func tabBarDidRequestTogglePersistent(tabID: TabID)
    func tabBarDidRequestToggleSidebar()
    func tabBarDidRequestPeek()
    func tabBarDidRequestSessions(from anchor: NSView)
}

extension TerminalTabBarDelegate {
    func tabBarDidRequestClose(tabID: TabID) {}
    func tabBarDidReorder(tabID: TabID, toIndex: Int) {}
    func tabBarDidRequestCloseOthers(tabID: TabID) {}
    func tabBarDidRequestRename(tabID: TabID) {}
    func tabBarDidRequestSplit(tabID: TabID, direction: SplitDirection) {}
    func tabBarDidRequestTogglePersistent(tabID: TabID) {}
    func tabBarDidRequestToggleSidebar() {}
    func tabBarDidRequestPeek() {}
    func tabBarDidRequestSessions(from anchor: NSView) {}
}

enum TabContextCommand {
    case close
    case closeOthers
    case rename
    case splitHorizontal
    case splitVertical
    case togglePersistent
}

/// Frame-laid tab strip. Pills compress toward a minimum width and, once they no
/// longer fit, spill into a trailing overflow menu (the visible window always keeps
/// the active tab). Supports drag-to-reorder and a right-click context menu.
@MainActor
final class TerminalTabBarView: NSView {
    weak var delegate: TerminalTabBarDelegate?

    private let newTabButton = SoftIconButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    private let overflowButton = SoftIconButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
    private var tabs: [Tab] = []
    private var activeTabID: TabID?
    private var pillsByID: [TabID: TabPillView] = [:]
    private var orderedPills: [TabPillView] = []

    // Layout metrics. Sessions, new-tab, and overflow share one hit target and one
    // glyph size so the row reads as a single control set, not three different buttons.
    private let edgeInset = HarnessDesign.Spacing.md
    private let controlSize: CGFloat = HarnessDesign.chromeIconButtonSize
    private let controlGap = HarnessDesign.Spacing.sm
    /// Stacked-squares button that opens the session switcher.
    private let sessionsButton = SoftIconButton(frame: .zero)
    private let pillSpacing = HarnessDesign.Spacing.xs
    private let minPillWidth: CGFloat = 120
    private let maxPillWidth: CGFloat = 300
    /// 1pt rules between neighbouring inactive tabs (none touch the active or hovered tab).
    private var dividers: [CALayer] = []

    /// Extra leading inset so the tab strip clears the macOS traffic lights when the
    /// sidebar is collapsed (content shifts to x=0 under `.fullSizeContentView`). 0
    /// when the sidebar is visible. Driven (and animated) by the split controller.
    var leadingInset: CGFloat = 0 {
        didSet { guard leadingInset != oldValue else { return }; needsLayout = true }
    }

    /// Leading x of the first pill: the sessions glyph, then the same gap again.
    private var sessionsButtonX: CGFloat { leadingInset + controlGap }
    private var contentLeft: CGFloat { sessionsButtonX + controlSize + controlGap }

    // Drag-reorder state.
    private weak var draggingPill: TabPillView?
    private var lastPeekUptime: TimeInterval = 0

    public override func scrollWheel(with event: NSEvent) {
        let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) && abs(event.scrollingDeltaX) > 8
        guard horizontal else {
            super.scrollWheel(with: event)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastPeekUptime > 0.45 {
            lastPeekUptime = now
            delegate?.tabBarDidRequestPeek()
        }
    }
    private var dragGrabOffsetX: CGFloat = 0
    private var dragTargetIndex: Int?
    private var visibleStart = 0
    private var visibleCount = 0
    private var currentPillWidth: CGFloat = 0
    /// Laid-out width of every pill, in tab order. Drag math uses these, not one shared pitch.
    private var pillWidths: [CGFloat] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        HarnessDesign.applyTabBarChrome(to: self)

        newTabButton.style = .glyph
        newTabButton.setSymbol("plus", accessibilityDescription: "New tab", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        newTabButton.toolTip = "New tab (⌘T)"
        newTabButton.target = self
        newTabButton.action = #selector(addNewTab)
        newTabButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(newTabButton)

        overflowButton.style = .glyph
        overflowButton.setSymbol("chevron.down", accessibilityDescription: "More tabs", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        overflowButton.toolTip = "More tabs"
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu)
        overflowButton.translatesAutoresizingMaskIntoConstraints = true
        overflowButton.isHidden = true
        addSubview(overflowButton)

        sessionsButton.style = .glyph
        sessionsButton.setSymbol("square.stack", accessibilityDescription: "Sessions", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        sessionsButton.toolTip = "Sessions (⌃⌘S)"
        sessionsButton.target = self
        sessionsButton.action = #selector(showSessions)
        sessionsButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(sessionsButton)

        let height = heightAnchor.constraint(equalToConstant: HarnessDesign.tabBarHeight)
        height.priority = .defaultHigh
        height.isActive = true
    }

    func reload(tabs: [Tab], activeTabID: TabID?) {
        // A metadata-driven reload can land mid-drag (agent status updates fire often);
        // commit the in-flight reorder first instead of silently discarding the gesture.
        if let dragging = draggingPill { handleDragEnded(dragging) }
        self.tabs = tabs
        self.activeTabID = activeTabID
        for pill in orderedPills { pill.removeFromSuperview() }
        orderedPills.removeAll(keepingCapacity: true)
        pillsByID.removeAll(keepingCapacity: true)
        draggingPill = nil
        dragTargetIndex = nil

        for (index, tab) in tabs.enumerated() {
            let id = tab.id
            // ⌘1–9 switch to the first nine tabs; past that, no hint.
            let pill = TabPillView(tab: tab, isActive: tab.id == activeTabID, position: index < 9 ? index + 1 : nil)
            pill.translatesAutoresizingMaskIntoConstraints = true
            pill.toolTip = HarnessDesign.shortenPath(tab.cwd)
            pill.onSelect = { [weak self] id in self?.delegate?.tabBarDidSelect(tabID: id) }
            pill.onClose = { [weak self] id in self?.delegate?.tabBarDidRequestClose(tabID: id) }
            pill.onDragChanged = { [weak self] p, loc in self?.handleDragChanged(p, windowLocation: loc) }
            pill.onDragEnded = { [weak self] p in self?.handleDragEnded(p) }
            pill.onContextCommand = { [weak self] cmd in self?.handleContext(cmd, tabID: id) }
            pill.onHoverChanged = { [weak self] in self?.updateDividers() }
            addSubview(pill)
            orderedPills.append(pill)
            pillsByID[tab.id] = pill
        }
        needsLayout = true
        applyChrome()
    }

    /// Update titles/status of existing pills without rebuilding, for live PWD /
    /// title / agent updates. Falls back to a full reload if the set of tabs changed.
    func refreshMetadata(tabs: [Tab], activeTabID: TabID?) {
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
            pillsByID[tab.id]?.toolTip = HarnessDesign.shortenPath(tab.cwd)
        }
        needsLayout = true // active tab change can shift the visible window
    }

    func applyChrome() {
        HarnessDesign.applyTabBarChrome(to: self)
        for pill in orderedPills {
            pill.applyChrome(isActive: pill.tabID == activeTabID)
        }
        newTabButton.applyChrome()
        overflowButton.applyChrome()
        sessionsButton.applyChrome()
        updateDividers()
    }

    /// The sessions button, for anchoring the switcher from a keyboard shortcut.
    var sessionsAnchor: NSView { sessionsButton }

    @objc private func showSessions() {
        delegate?.tabBarDidRequestSessions(from: sessionsButton)
    }

    @objc private func addNewTab() {
        delegate?.tabBarDidRequestNewTab()
    }

    /// Animate the traffic-light clearance inset (driven by the split controller as the
    /// sidebar collapses/expands). 0 = sidebar visible, ~72 = collapsed.
    func setLeadingInset(_ inset: CGFloat) {
        leadingInset = inset
        layoutSubtreeIfNeeded()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let buttonY = rowCenterY - controlSize / 2
        sessionsButton.frame = NSRect(
            x: sessionsButtonX,
            y: buttonY,
            width: controlSize,
            height: controlSize
        )
        // "+" is pinned to the trailing edge, like the reference title bars.
        newTabButton.frame = NSRect(x: newTabX, y: buttonY, width: controlSize, height: controlSize)
        guard draggingPill == nil else { return } // drag drives its own positioning
        layoutPills()
        updateDividers()
    }

    private var newTabX: CGFloat { bounds.width - edgeInset - controlSize }

    /// The row's centerline in this (unflipped) view: level with the traffic lights.
    private var rowCenterY: CGFloat { bounds.height - HarnessDesign.titleRowCenter }

    /// Hairlines between neighbouring inactive pills. The active pill has its own border,
    /// and a hovered pill has a fill, so neither gets a rule beside it.
    private func updateDividers() {
        let visible = orderedPills.filter { !$0.isHidden }
        let slots = ChromeLayout.dividerSlots(
            count: visible.count,
            activeIndex: visible.firstIndex { $0.tabID == activeTabID },
            hoveredIndex: visible.firstIndex { $0.isHovered }
        )
        while dividers.count < slots.count {
            let rule = CALayer()
            rule.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer?.addSublayer(rule)
            dividers.append(rule)
        }
        let color = HarnessChrome.current.borderStrong.cgColor
        let height = HarnessDesign.tabPillHeight * 0.55
        for (index, rule) in dividers.enumerated() {
            guard index < slots.count, draggingPill == nil else {
                rule.isHidden = true
                continue
            }
            let left = visible[slots[index]].frame
            rule.isHidden = false
            rule.backgroundColor = color
            rule.frame = NSRect(x: left.maxX + pillSpacing / 2 - 0.5, y: left.midY - height / 2, width: 1, height: height)
        }
    }

    private func layoutPills() {
        let count = orderedPills.count
        let buttonY = rowCenterY - controlSize / 2
        guard count > 0 else {
            overflowButton.isHidden = true
            return
        }

        // Hug each label. Stretching one short title out to the max width leaves a hollow pill.
        let inlineAvail = newTabX - controlGap - contentLeft
        let naturals = orderedPills.map { $0.preferredWidth(min: minPillWidth, max: maxPillWidth) }
        let naturalSum = naturals.reduce(0, +) + pillSpacing * CGFloat(max(count - 1, 0))

        var needsOverflow = false
        var vCount = count
        var widths = naturals
        if naturalSum > inlineAvail {
            let even = (inlineAvail - pillSpacing * CGFloat(count - 1)) / CGFloat(count)
            if even < minPillWidth {
                needsOverflow = true
                let avail = newTabX - controlGap * 2 - controlSize - contentLeft
                vCount = min(count, max(1, Int((avail + pillSpacing) / (minPillWidth + pillSpacing))))
                let shrunk = max(minPillWidth, (avail - pillSpacing * CGFloat(vCount - 1)) / CGFloat(vCount))
                widths = Array(repeating: shrunk, count: count)
            } else {
                widths = Array(repeating: even, count: count)
            }
        }

        // Slide the visible window so it always contains the active tab.
        var start = 0
        if needsOverflow,
           let activeID = activeTabID,
           let activeIdx = orderedPills.firstIndex(where: { $0.tabID == activeID }),
           activeIdx >= vCount {
            start = activeIdx - vCount + 1
        }
        visibleStart = start
        visibleCount = vCount
        pillWidths = widths
        currentPillWidth = widths[min(start, widths.count - 1)]

        let y = rowCenterY - HarnessDesign.tabPillHeight / 2
        var x = contentLeft
        for (i, pill) in orderedPills.enumerated() {
            let visible = i >= start && i < start + vCount
            pill.isHidden = !visible
            guard visible else { continue }
            let pillWidth = widths[i]
            pill.frame = NSRect(x: x, y: y, width: pillWidth, height: HarnessDesign.tabPillHeight)
            x += pillWidth + pillSpacing
        }
        overflowButton.isHidden = !needsOverflow
        if needsOverflow {
            overflowButton.frame = NSRect(
                x: newTabX - controlGap - controlSize,
                y: buttonY,
                width: controlSize,
                height: controlSize
            )
        }
    }

    private func visibleWidths() -> [Double] {
        let end = min(pillWidths.count, visibleStart + visibleCount)
        guard visibleStart < end else { return [] }
        return pillWidths[visibleStart..<end].map { Double($0) }
    }

    private func slotX(_ slot: Int) -> CGFloat {
        let origin = ChromeLayout.slotOrigin(index: slot, widths: visibleWidths(), spacing: Double(pillSpacing))
        return contentLeft + CGFloat(origin)
    }

    private func widthForVisibleSlot(_ slot: Int) -> CGFloat {
        let widths = visibleWidths()
        guard widths.indices.contains(slot) else { return currentPillWidth }
        return CGFloat(widths[slot])
    }

    // MARK: - Drag reorder

    private func handleDragChanged(_ pill: TabPillView, windowLocation: NSPoint) {
        let loc = convert(windowLocation, from: nil)
        if draggingPill !== pill {
            draggingPill = pill
            dragGrabOffsetX = loc.x - pill.frame.minX
            pill.layer?.zPosition = 100
        }
        var f = pill.frame
        f.origin.x = max(contentLeft, min(loc.x - dragGrabOffsetX, bounds.width - edgeInset - f.width))
        pill.frame = f
        repositionForDrag(pill)
    }

    private func repositionForDrag(_ dragged: TabPillView) {
        // Reorder is scoped to the visible window; overflow pills stay put (v1).
        let visible = orderedPills.enumerated()
            .filter { $0.offset >= visibleStart && $0.offset < visibleStart + visibleCount }
            .map(\.element)
        let others = visible.filter { $0 !== dragged }
        // Target slot from the dragged pill's own position (stable — independent of
        // the others, which are mid-animation).
        let widths = visibleWidths()
        let target = ChromeLayout.dragTargetSlot(
            leadingX: Double(dragged.frame.minX - contentLeft),
            widths: widths,
            spacing: Double(pillSpacing)
        )
        dragTargetIndex = visibleStart + target

        let y = rowCenterY - HarnessDesign.tabPillHeight / 2
        var oi = 0
        HarnessMotion.animate(HarnessDesign.Motion.fast) { _ in
            for slot in 0..<visible.count where slot != target {
                guard oi < others.count else { break }
                let pill = others[oi]; oi += 1
                pill.animator().frame = NSRect(
                    x: self.slotX(slot),
                    y: y,
                    width: self.widthForVisibleSlot(slot),
                    height: HarnessDesign.tabPillHeight
                )
            }
        }
    }

    private func handleDragEnded(_ pill: TabPillView) {
        pill.layer?.zPosition = 0
        let target = dragTargetIndex
        let from = orderedPills.firstIndex { $0 === pill }
        draggingPill = nil
        dragTargetIndex = nil

        if let target, let from, target != from {
            // Commit; the resulting snapshot reload rebuilds pills in the new order.
            delegate?.tabBarDidReorder(tabID: pill.tabID, toIndex: target)
        } else {
            // No move — snap back into place.
            needsLayout = true
        }
    }

    // MARK: - Context + overflow menus

    private func handleContext(_ cmd: TabContextCommand, tabID: TabID) {
        switch cmd {
        case .close: delegate?.tabBarDidRequestClose(tabID: tabID)
        case .closeOthers: delegate?.tabBarDidRequestCloseOthers(tabID: tabID)
        case .rename: delegate?.tabBarDidRequestRename(tabID: tabID)
        case .splitHorizontal: delegate?.tabBarDidRequestSplit(tabID: tabID, direction: .horizontal)
        case .splitVertical: delegate?.tabBarDidRequestSplit(tabID: tabID, direction: .vertical)
        case .togglePersistent: delegate?.tabBarDidRequestTogglePersistent(tabID: tabID)
        }
    }

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        for (i, tab) in tabs.enumerated() where !(i >= visibleStart && i < visibleStart + visibleCount) {
            let item = NSMenuItem(title: tabDisplayTitle(tab), action: #selector(overflowItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id.uuidString
            // A waiting tab gets the bell glyph (same vocabulary as the tab pill) — a
            // checkmark would read as "this item is selected", not "needs attention".
            // Otherwise a kept-alive tab shows the persistence pin so the flag is visible
            // even when the tab has spilled into the overflow menu.
            if tab.status == .waiting {
                item.image = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: "Waiting")
            } else if tab.persistent {
                item.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Kept running after quit")
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: overflowButton.frame.minX, y: overflowButton.frame.minY), in: self)
    }

    @objc private func overflowItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        delegate?.tabBarDidSelect(tabID: id)
    }
}

@MainActor
private func tabDisplayTitle(_ tab: Tab) -> String {
    let base = SurfaceIdentity.label(
        directory: tab.cwd,
        program: tab.currentCommand,
        agent: tab.agent?.kind.commandToken
    )
    return TabChip.title(base: base, app: tab.programMark?.app)
}

/// Effective agent kind for the tab — daemon-detected first, then a permissive
/// inference from the shell title. Lets us paint brand colors on the dot even
/// when proc-tree detection misses the agent (e.g. Claude Code via Node).
@MainActor
private func tabAgentKind(for tab: Tab) -> AgentKind? {
    tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title)
}

@MainActor
private final class TabPillView: NSView {
    let tabID: TabID
    var onSelect: ((TabID) -> Void)?
    var onClose: ((TabID) -> Void)?
    var onDragChanged: ((TabPillView, NSPoint) -> Void)?
    var onDragEnded: ((TabPillView) -> Void)?
    var onContextCommand: ((TabContextCommand) -> Void)?
    var onHoverChanged: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    /// Leading app tile: `>_` for a shell, the brand tile for an agent.
    private let iconTile = IconTileView(side: HarnessDesign.tabIconTileSize)
    /// "Kept alive" flag: a small pin shown at the leading edge when this tab is pinned to
    /// survive a clean quit (`tab.persistent`). The visible counterpart of the context-menu
    /// "Keep Tab Running After Quit" checkmark — a tmux-style window flag for persistence.
    private let persistentIcon = NSImageView()
    /// Working spinner / needs-you / done / error mark before the shortcut hint.
    private let statusView = TabStatusView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    /// Collapse the status slot (and its gap) when there's nothing to show.
    private var statusWidth: NSLayoutConstraint!
    private var statusGap: NSLayoutConstraint!
    private static let statusSide: CGFloat = 12
    private var glassView: NSView?
    /// ⌘N hint, shown at the trailing edge for the first 9 tabs and
    /// swapped for the close button on hover. Empty for tabs past position 9.
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hasShortcut: Bool
    private var persistentIconWidth: NSLayoutConstraint!
    private var closeWidthConstraint: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var isActive = false
    private(set) var isHovered = false
    private var status: TabStatus = .idle
    /// Whether this tab is pinned to survive a clean quit — drives the context-menu checkmark.
    private var isPersistent = false
    private var activity: TabActivity = .none

    // Drag detection.
    private var mouseDownLocation: NSPoint?
    private var isDragging = false

    // The tab strip lives in the window's titlebar drag region (`.fullSizeContentView`).
    // Without this, AppKit interprets a drag that starts on a pill as a window move and
    // pre-empts our reorder. Returning false lets the pill's own `mouseDragged` →
    // `onDragChanged` reorder run smoothly; the empty tab-bar background keeps the default
    // (true), so dragging there still moves the window.
    override var mouseDownCanMoveWindow: Bool { false }

    init(tab: Tab, isActive: Bool, position: Int?) {
        tabID = tab.id
        hasShortcut = position != nil
        super.init(frame: .zero)
        self.isActive = isActive
        self.status = tab.status
        self.isPersistent = tab.persistent

        wantsLayer = true
        // Card radius (not control) so the active pill reads identically to the
        // selected session card in the sidebar.
        layer?.cornerRadius = HarnessDesign.tabPillHeight / 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        installGlass()

        titleLabel.font = HarnessDesign.Typography.tabTitle
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .left
        titleLabel.stringValue = tabDisplayTitle(tab)
        HarnessDesign.prepareChromeLabel(titleLabel)
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
        closeButton.layer?.cornerRadius = HarnessDesign.Radius.badge
        closeButton.layer?.cornerCurve = .continuous

        iconTile.translatesAutoresizingMaskIntoConstraints = false

        persistentIcon.translatesAutoresizingMaskIntoConstraints = false
        persistentIcon.imageScaling = .scaleProportionallyUpOrDown
        persistentIcon.isHidden = true
        persistentIcon.toolTip = "Kept running after quit"
        persistentIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Kept running after quit")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold))

        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        shortcutLabel.alignment = .right
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.stringValue = position.map { "⌘\($0)" } ?? ""
        HarnessDesign.prepareChromeLabel(shortcutLabel)
        shortcutLabel.isHidden = !hasShortcut
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)

        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.isHidden = true

        addSubview(persistentIcon)
        addSubview(iconTile)
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addSubview(closeButton)
        addSubview(statusView)

        // Title centers inside the pill with the close button floating on the
        // right edge and the agent brand icon (when present) on the left. Leading
        // edge inset matches the close button's trailing inset so the title stays
        // optically centered even when both are visible.
        persistentIconWidth = persistentIcon.widthAnchor.constraint(equalToConstant: 0)
        statusWidth = statusView.widthAnchor.constraint(equalToConstant: 0)
        statusGap = statusView.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor)
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: iconTile.trailingAnchor, constant: HarnessDesign.Spacing.md)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.md)
        closeWidthConstraint = closeButton.widthAnchor.constraint(equalToConstant: 0)
        let closeHeight = closeButton.heightAnchor.constraint(equalToConstant: 14)
        [closeTrailing, closeHeight].forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            // Leading run: [persistence pin?][agent icon?] — each collapses to zero width when
            // absent, so a plain tab keeps the agent icon flush at the same inset as before.
            persistentIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.tabIconTileInset),
            persistentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            persistentIcon.heightAnchor.constraint(equalToConstant: 12),
            persistentIconWidth,
            iconTile.leadingAnchor.constraint(equalTo: persistentIcon.trailingAnchor),
            iconTile.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusView.leadingAnchor, constant: -HarnessDesign.Spacing.md),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -HarnessDesign.Spacing.xs),
            // Text needs more room than the tile from the capsule's rounded end.
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.lg),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeWidthConstraint,
            closeHeight,
            // Status mark sits on the right of the pill, just before the shortcut.
            statusGap,
            statusView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusWidth,
            statusView.heightAnchor.constraint(equalToConstant: 12),
        ])

        iconTile.apply(IconTileView.content(for: tabAgentKind(for: tab)))
        setPersistentIndicator(tab.persistent)
        activity = TabActivity.of(tab)
        setAccessibilityLabel(Self.accessibilityLabel(tab))
        applyChrome(isActive: isActive)
    }

    private static func accessibilityLabel(_ tab: Tab) -> String {
        let title = tabDisplayTitle(tab)
        var parts = [title]
        if let state = TabStatusView.label(TabActivity.of(tab)) { parts.append(state) }
        if let message = tab.programMark?.message, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: ", ")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        HarnessDesign.alignChromeText([titleLabel, shortcutLabel], in: self)
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

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged?()
        HarnessMotion.animate(HarnessDesign.Motion.microFast) { _ in
            closeButton.animator().alphaValue = 1
            self.closeWidthConstraint.constant = 14
            shortcutLabel.animator().alphaValue = 0
            applyChrome(isActive: isActive)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged?()
        HarnessMotion.animate(HarnessDesign.Motion.microFast) { _ in
            closeButton.animator().alphaValue = 0
            self.closeWidthConstraint.constant = 0
            shortcutLabel.animator().alphaValue = hasShortcut ? 1 : 0
            applyChrome(isActive: isActive)
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        isDragging = false
        // Selection/drag are resolved on mouseUp/mouseDragged.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        if !isDragging, abs(event.locationInWindow.x - start.x) > 4 {
            isDragging = true
        }
        if isDragging {
            onDragChanged?(self, event.locationInWindow)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if isDragging {
            onDragEnded?(self)
        } else if !closeButton.frame.contains(local), bounds.contains(local) {
            // Double-click anywhere on the pill (except the close button) renames it,
            // matching the browser/Terminal.app convention; a single click selects.
            if event.clickCount >= 2 {
                onContextCommand?(.rename)
            } else {
                onSelect?(tabID)
            }
        }
        mouseDownLocation = nil
        isDragging = false
        super.mouseUp(with: event)
    }

    // Middle-click closes the tab (standard tab-bar affordance). Swallow the press
    // so it doesn't fall through, and act on release while still over the pill.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) { onContextCommand?(.close) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onSelect?(tabID) // make this the active tab so menu actions target it
        let menu = NSMenu()
        menu.addItem(menuItem("Close Tab", #selector(ctxClose)))
        menu.addItem(menuItem("Close Other Tabs", #selector(ctxCloseOthers)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Rename…", #selector(ctxRename)))
        menu.addItem(.separator())
        // Per-tab persistence pin: survives a clean quit even when its session and the global
        // keep-on-quit are off. The checkmark reflects the current pinned state.
        let pin = menuItem("Keep Tab Running After Quit", #selector(ctxTogglePersistent))
        pin.state = isPersistent ? .on : .off
        menu.addItem(pin)
        menu.addItem(.separator())
        menu.addItem(menuItem("Split Right", #selector(ctxSplitHorizontal)))
        menu.addItem(menuItem("Split Down", #selector(ctxSplitVertical)))
        return menu
    }

    private func menuItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func ctxClose() { onContextCommand?(.close) }
    @objc private func ctxCloseOthers() { onContextCommand?(.closeOthers) }
    @objc private func ctxRename() { onContextCommand?(.rename) }
    @objc private func ctxSplitHorizontal() { onContextCommand?(.splitHorizontal) }
    @objc private func ctxSplitVertical() { onContextCommand?(.splitVertical) }
    @objc private func ctxTogglePersistent() { onContextCommand?(.togglePersistent) }

    @objc private func closeClicked() {
        onClose?(tabID)
    }

    /// Width that fits every part laid out above, clamped to the tab bar's limits:
    /// inset, tile, gap, title, gap, [status, gap], shortcut, trailing inset.
    func preferredWidth(min: CGFloat, max: CGFloat) -> CGFloat {
        let title = ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: titleLabel.font as Any]).width) + 4
        let shortcut = shortcutLabel.isHidden
            ? 0
            : ceil((shortcutLabel.stringValue as NSString).size(withAttributes: [.font: shortcutLabel.font as Any]).width)
        let leading = HarnessDesign.tabIconTileInset + persistentIconWidth.constant + HarnessDesign.tabIconTileSize + HarnessDesign.Spacing.md
        let status = statusWidth.constant > 0 ? Self.statusSide + HarnessDesign.Spacing.sm : 0
        let trailing = HarnessDesign.Spacing.md + status + shortcut + HarnessDesign.Spacing.lg
        return CGFloat(ChromeLayout.huggedPillWidth(
            labelWidth: Double(leading + title),
            accessoryWidth: Double(trailing),
            min: Double(min),
            max: Double(max)
        ))
    }

    func update(tab: Tab, isActive: Bool) {
        status = tab.status
        isPersistent = tab.persistent
        titleLabel.stringValue = tabDisplayTitle(tab)
        iconTile.apply(IconTileView.content(for: tabAgentKind(for: tab)))
        setPersistentIndicator(tab.persistent)
        activity = TabActivity.of(tab)
        setAccessibilityLabel(Self.accessibilityLabel(tab))
        applyChrome(isActive: isActive)
    }

    /// Show/hide the leading "kept alive" pin (the visible form of `tab.persistent`).
    private func setPersistentIndicator(_ visible: Bool) {
        persistentIcon.isHidden = !visible
        persistentIconWidth.constant = visible ? 14 : 0
    }

    private func installGlass() {
        let radius = HarnessDesign.tabPillHeight / 2
        guard let glass = HarnessDesign.makeLiquidGlass(cornerRadius: radius) else { return }
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        glass.isHidden = true
        glassView = glass
    }

    // VoiceOver: each pill is a radio button in the tab group, selected when active, and
    // pressing it selects the tab.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    override func accessibilityRoleDescription() -> String? { "tab" }
    override func accessibilityValue() -> Any? { NSNumber(value: isActive) }
    override func isAccessibilitySelected() -> Bool { isActive }
    override func accessibilityPerformPress() -> Bool {
        onSelect?(tabID)
        return true
    }

    func applyChrome(isActive: Bool) {
        self.isActive = isActive
        let c = HarnessDesign.chrome
        layer?.cornerRadius = HarnessDesign.tabPillHeight / 2

        if isActive {
            if let glass = glassView {
                glass.isHidden = false
                // Dark glass is a faint lift. Light glass is only a hint of white,
                // so the capsule doesn't turn into a bright chip on the pale bar.
                let glassTint = HarnessDesign.activeGlassTint(isDark: c.isDark, textPrimary: c.textPrimary)
                HarnessDesign.setLiquidGlassTint(glassTint, on: glass)
                layer?.backgroundColor = NSColor.clear.cgColor
            } else {
                layer?.backgroundColor = c.activePillFill.cgColor
            }
            layer?.borderWidth = 1
            layer?.borderColor = c.textPrimary.withAlphaComponent(HarnessDesign.activeGlassBorderAlpha(isDark: c.isDark)).cgColor
            if c.isDark {
                HarnessDesign.applyShadow(.elevation1, to: layer)
            } else {
                HarnessDesign.applyShadow(.none, to: layer)
            }
            titleLabel.textColor = c.activePillLabel
        } else if isHovered {
            glassView?.isHidden = true
            layer?.backgroundColor = c.rowHoverFill.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            HarnessDesign.applyShadow(.none, to: layer)
            titleLabel.textColor = c.textPrimary
        } else {
            glassView?.isHidden = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            HarnessDesign.applyShadow(.none, to: layer)
            titleLabel.textColor = c.textSecondary
        }

        HarnessDesign.applyChromeLabelAppearance([titleLabel, shortcutLabel], isDark: c.isDark)
        iconTile.applyChrome()
        // The active tab is in front of you; it only flags something that needs you.
        let shown: TabActivity = isActive && (activity == .working || activity == .done) ? .none : activity
        statusView.apply(shown, tint: c.accent)
        statusWidth.constant = shown == .none ? 0 : Self.statusSide
        statusGap.constant = shown == .none ? 0 : -HarnessDesign.Spacing.sm
        closeButton.contentTintColor = c.textTertiary
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        // Persistence pin reads as an intentional "kept alive" marker, so it carries the
        // brand accent rather than the neutral title color — visible on active and idle tabs alike.
        persistentIcon.contentTintColor = c.accent
        // ⌘N hint: a touch brighter on the active tab, quiet otherwise.
        shortcutLabel.textColor = isActive ? c.textSecondary : c.textTertiary
    }
}
