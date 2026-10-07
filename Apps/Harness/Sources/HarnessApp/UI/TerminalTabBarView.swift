import AppKit
import HarnessCore

/// Blurs what sits behind it and fades that blur out toward the left.
/// The layer has no fill, so the bar does not pick up a second color.
@MainActor
final class HorizontalFadeBlur: NSView {
    private let fadeMask = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.clear.cgColor
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = fadeMask
        apply(isDark: true)
    }

    /// Light mode keeps only a whisper of blur. A stronger filter picks up a
    /// gray edge against the pale bar and reads as a dark patch.
    func apply(isDark: Bool) {
        // Light mode adds no Core Image blur. The filter reads as a gray patch
        // on a pale bar. Dark mode keeps a faint right-edge fade.
        if isDark {
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(3, forKey: kCIInputRadiusKey)
            layer?.backgroundFilters = filter.map { [$0] } ?? []
            fadeMask.colors = [
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
                NSColor.black.withAlphaComponent(0.28).cgColor,
            ]
        } else {
            layer?.backgroundFilters = []
            fadeMask.colors = [
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
                NSColor.clear.cgColor,
            ]
        }
        fadeMask.locations = [0, 0.55, 1]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        fadeMask.frame = bounds
    }
}

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
    private let splitRight = SoftIconButton(frame: .zero)
    private let splitDown = SoftIconButton(frame: .zero)
    /// Colorless blur behind the split icons. It fades out to the left and
    /// adds no tint of its own, so the bar stays one surface.
    private let splitBlur = HorizontalFadeBlur()
    private var tabs: [Tab] = []
    private var activeTabID: TabID?
    private var pillsByID: [TabID: TabPillView] = [:]
    private var orderedPills: [TabPillView] = []

    // Layout metrics. Sidebar, new-tab, and overflow share one hit target and one
    // glyph size so the row reads as a single control set, not three different buttons.
    private let edgeInset: CGFloat = 10
    private let controlSize: CGFloat = HarnessDesign.chromeIconButtonSize
    private let controlGap: CGFloat = 6
    private let sidebarToggle = SoftIconButton(frame: .zero)
    private let pillSpacing = HarnessDesign.Spacing.xs
    private let minPillWidth: CGFloat = 200
    private let maxPillWidth: CGFloat = 320

    /// Extra leading inset so the tab strip clears the macOS traffic lights when the
    /// sidebar is collapsed (content shifts to x=0 under `.fullSizeContentView`). 0
    /// when the sidebar is visible. Driven (and animated) by the split controller.
    var leadingInset: CGFloat = 0 {
        didSet { guard leadingInset != oldValue else { return }; needsLayout = true }
    }

    /// Leading x of the first pill. The sidebar glyph sits in `controlGap`, then the
    /// same gap again, so the space from glyph to pill matches the space from pill to plus.
    private var sidebarButtonX: CGFloat { leadingInset + controlGap }
    private var contentLeft: CGFloat { sidebarButtonX + controlSize + controlGap }

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

        sidebarToggle.style = .glyph
        sidebarToggle.setSymbol("sidebar.left", accessibilityDescription: "Toggle sidebar", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        sidebarToggle.toolTip = "Hide sidebar (⌘\\)"
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebar)
        sidebarToggle.translatesAutoresizingMaskIntoConstraints = true
        addSubview(sidebarToggle)

        addSubview(splitBlur)

        splitRight.style = .glyph
        splitRight.setSymbol("rectangle.split.2x1", accessibilityDescription: "Split right", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        splitRight.toolTip = "Split right"
        splitRight.target = self
        splitRight.action = #selector(splitRightClicked)
        splitRight.translatesAutoresizingMaskIntoConstraints = true
        addSubview(splitRight)

        splitDown.style = .glyph
        splitDown.setSymbol("rectangle.split.1x2", accessibilityDescription: "Split down", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        splitDown.toolTip = "Split down"
        splitDown.target = self
        splitDown.action = #selector(splitDownClicked)
        splitDown.translatesAutoresizingMaskIntoConstraints = true
        addSubview(splitDown)

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
            addSubview(pill)
            orderedPills.append(pill)
            pillsByID[tab.id] = pill
        }
        needsLayout = true
        applyChrome()
        liftSplitCluster()
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
        sidebarToggle.applyChrome()
        splitRight.applyChrome()
        splitDown.applyChrome()
        splitBlur.apply(isDark: HarnessChrome.current.isDark)
    }

    /// Split icons stay above the pills. The blur view is between them, so a tab
    /// that reaches the trailing edge softens instead of colliding with the glyphs.
    private func liftSplitCluster() {
        addSubview(splitBlur, positioned: .above, relativeTo: orderedPills.last)
        addSubview(splitRight, positioned: .above, relativeTo: splitBlur)
        addSubview(splitDown, positioned: .above, relativeTo: splitRight)
    }

    @objc private func splitRightClicked() {
        guard let id = activeTabID else { return }
        delegate?.tabBarDidRequestSplit(tabID: id, direction: .horizontal)
    }

    @objc private func splitDownClicked() {
        guard let id = activeTabID else { return }
        delegate?.tabBarDidRequestSplit(tabID: id, direction: .vertical)
    }

    func setSidebarCollapsed(_ collapsed: Bool) {
        let symbol = collapsed ? "sidebar.right" : "sidebar.left"
        sidebarToggle.setSymbol(symbol, accessibilityDescription: "Toggle sidebar", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        sidebarToggle.toolTip = collapsed ? "Show sidebar (⌘\\)" : "Hide sidebar (⌘\\)"
    }

    @objc private func toggleSidebar() {
        delegate?.tabBarDidRequestToggleSidebar()
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
        let buttonY = (bounds.height - controlSize) / 2
        sidebarToggle.frame = NSRect(
            x: sidebarButtonX,
            y: buttonY,
            width: controlSize,
            height: controlSize
        )
        layoutSplitCluster(buttonY: buttonY)
        guard draggingPill == nil else { return } // drag drives its own positioning
        layoutPills()
        liftSplitCluster()
    }

    /// Width of the two split glyphs plus the gap between them.
    private var splitClusterWidth: CGFloat { controlSize * 2 + 4 }

    private var splitClusterMinX: CGFloat { bounds.width - edgeInset - splitClusterWidth }

    private func layoutSplitCluster(buttonY: CGFloat) {
        let x = splitClusterMinX
        splitRight.frame = NSRect(x: x, y: buttonY, width: controlSize, height: controlSize)
        splitDown.frame = NSRect(x: x + controlSize + 4, y: buttonY, width: controlSize, height: controlSize)
        // Wide and faint. The view itself carries no color; the mask only
        // reveals a little blur at the right edge.
        let fadeWidth: CGFloat = 150
        splitBlur.frame = NSRect(x: bounds.width - fadeWidth, y: 0, width: fadeWidth, height: bounds.height)
    }

    private func layoutPills() {
        let count = orderedPills.count
        let buttonY = (bounds.height - controlSize) / 2
        guard count > 0 else {
            newTabButton.frame = NSRect(x: contentLeft, y: buttonY, width: controlSize, height: controlSize)
            overflowButton.isHidden = true
            return
        }

        // Hug each label. Stretching one short title out to the max width leaves a hollow pill.
        let inlineAvail = bounds.width - contentLeft - edgeInset - controlSize - controlGap
        let naturals = orderedPills.map { $0.preferredWidth(min: minPillWidth, max: maxPillWidth) }
        let naturalSum = naturals.reduce(0, +) + pillSpacing * CGFloat(max(count - 1, 0))

        var needsOverflow = false
        var vCount = count
        var widths = naturals
        if naturalSum > inlineAvail {
            let even = (inlineAvail - pillSpacing * CGFloat(count - 1)) / CGFloat(count)
            if even < minPillWidth {
                needsOverflow = true
                let avail = bounds.width - contentLeft - edgeInset - controlSize * 2 - controlGap * 2
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

        let y = (bounds.height - HarnessDesign.tabPillHeight) / 2
        var x = contentLeft
        for (i, pill) in orderedPills.enumerated() {
            let visible = i >= start && i < start + vCount
            pill.isHidden = !visible
            guard visible else { continue }
            let pillWidth = widths[i]
            pill.frame = NSRect(x: x, y: y, width: pillWidth, height: HarnessDesign.tabPillHeight)
            x += pillWidth + pillSpacing
        }
        // The loop leaves `pillSpacing` after the last pill. Replace it with the
        // same gap the sidebar glyph uses, so both ends of the row match.
        newTabButton.frame = NSRect(
            x: x - pillSpacing + controlGap,
            y: buttonY,
            width: controlSize,
            height: controlSize
        )

        // The plus stays visible, just left of the split cluster. Tabs may run
        // underneath that cluster; the blur sits in front of them.
        let plusLimit = splitClusterMinX - controlGap - controlSize
        if newTabButton.frame.maxX > plusLimit + controlSize {
            newTabButton.frame.origin.x = max(contentLeft, plusLimit)
        }

        overflowButton.isHidden = !needsOverflow
        if needsOverflow {
            overflowButton.frame = NSRect(
                x: splitClusterMinX - controlGap - controlSize,
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

        let y = (bounds.height - HarnessDesign.tabPillHeight) / 2
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

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let agentIcon = NSImageView()
    /// "Kept alive" flag: a small pin shown at the leading edge when this tab is pinned to
    /// survive a clean quit (`tab.persistent`). The visible counterpart of the context-menu
    /// "Keep Tab Running After Quit" checkmark — a tmux-style window flag for persistence.
    private let persistentIcon = NSImageView()
    /// Ghostty-style "AI is working" indicator: a tiny dot before the title that discretely
    /// shuttles between two spots while the tab's agent is producing output. Hidden otherwise.
    private let workingDot = NSView()
    private var glassView: NSView?
    /// ⌘N hint, shown at the trailing edge for the first 9 tabs and
    /// swapped for the close button on hover. Empty for tabs past position 9.
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hasShortcut: Bool
    private var agentIconWidth: NSLayoutConstraint!
    private var persistentIconWidth: NSLayoutConstraint!
    private var closeWidthConstraint: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var isActive = false
    private var isHovered = false
    private var status: TabStatus = .idle
    /// Whether this tab is pinned to survive a clean quit — drives the context-menu checkmark.
    private var isPersistent = false
    /// True when the leading glyph is the generic terminal symbol, so its tint
    /// follows the title instead of an agent brand color.
    private var usesGenericIcon = true

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

        agentIcon.translatesAutoresizingMaskIntoConstraints = false
        agentIcon.imageScaling = .scaleProportionallyUpOrDown
        agentIcon.isHidden = true

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

        workingDot.wantsLayer = true
        workingDot.layer?.cornerRadius = 1
        workingDot.translatesAutoresizingMaskIntoConstraints = false
        workingDot.isHidden = true

        addSubview(persistentIcon)
        addSubview(agentIcon)
        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addSubview(closeButton)
        addSubview(workingDot)

        // Title centers inside the pill with the close button floating on the
        // right edge and the agent brand icon (when present) on the left. Leading
        // edge inset matches the close button's trailing inset so the title stays
        // optically centered even when both are visible.
        agentIconWidth = agentIcon.widthAnchor.constraint(equalToConstant: 0)
        persistentIconWidth = persistentIcon.widthAnchor.constraint(equalToConstant: 0)
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: agentIcon.trailingAnchor, constant: 6)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.xs)
        closeWidthConstraint = closeButton.widthAnchor.constraint(equalToConstant: 0)
        let closeHeight = closeButton.heightAnchor.constraint(equalToConstant: 14)
        [closeTrailing, closeHeight].forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            // Leading run: [persistence pin?][agent icon?] — each collapses to zero width when
            // absent, so a plain tab keeps the agent icon flush at the same inset as before.
            persistentIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            persistentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            persistentIcon.heightAnchor.constraint(equalToConstant: 12),
            persistentIconWidth,
            agentIcon.leadingAnchor.constraint(equalTo: persistentIcon.trailingAnchor),
            agentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            agentIcon.heightAnchor.constraint(equalToConstant: 14),
            agentIconWidth,
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -HarnessDesign.Spacing.xs),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -HarnessDesign.Spacing.xs),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.sm),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeWidthConstraint,
            closeHeight,
            // Status dot sits on the right of the pill, just before the shortcut.
            workingDot.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor, constant: -8),
            workingDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            workingDot.widthAnchor.constraint(equalToConstant: 2),
            workingDot.heightAnchor.constraint(equalToConstant: 2),
        ])

        setAgentIcon(for: tab)
        setPersistentIndicator(tab.persistent)
        setWorkingDotVisible(Self.isAgentWorking(tab))
        setAccessibilityLabel(Self.accessibilityLabel(tab))
        applyChrome(isActive: isActive)

        // Re-evaluate the shuttle animation when the user toggles Reduce Motion mid-session,
        // matching the StatusDotView pattern so the dot follows the live setting immediately.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reduceMotionDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func reduceMotionDidChange() {
        // Re-apply the current dot visibility to pick up the new Reduce Motion setting.
        setWorkingDotVisible(!workingDot.isHidden)
    }

    /// Primary signal: a live OSC 9;4 progress report — terminal-native, exactly what Ghostty
    /// renders (Claude Code 2.0+ keep-alives one across each full turn, including thinking).
    /// Fallback: the process detector's output recency, for agents that don't emit 9;4 (codex).
    /// `waiting` only vetoes the fallback — an explicit progress report outranks a stale
    /// waiting status.
    private static func accessibilityLabel(_ tab: Tab) -> String {
        let title = tabDisplayTitle(tab)
        guard let mark = tab.programMark else { return title }
        var parts = [title, mark.attention.rawValue]
        if let message = mark.message, !message.isEmpty { parts.append(message) }
        return parts.joined(separator: ", ")
    }

    private static func isAgentWorking(_ tab: Tab) -> Bool {
        if let mark = tab.programMark {
            return mark.attention == .working
        }
        if tab.rootPane.allSurfaceIDs().contains(where: { SurfaceProgressTracker.shared.isActive($0) }) {
            return true
        }
        return tab.agent?.activity == .working && tab.status != .waiting
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
        HarnessMotion.animate(HarnessDesign.Motion.microFast) { _ in
            closeButton.animator().alphaValue = 1
            self.closeWidthConstraint.constant = 14
            shortcutLabel.animator().alphaValue = 0
            applyChrome(isActive: isActive)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
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

    /// Width that fits the identity and the shortcut, clamped to the tab bar's limits.
    func preferredWidth(min: CGFloat, max: CGFloat) -> CGFloat {
        let title = (titleLabel.stringValue as NSString).size(withAttributes: [.font: titleLabel.font as Any]).width
        let shortcut = shortcutLabel.isHidden
            ? 0
            : (shortcutLabel.stringValue as NSString).size(withAttributes: [.font: shortcutLabel.font as Any]).width + 8
        let icon: CGFloat = agentIconWidth?.constant ?? 0
        return CGFloat(ChromeLayout.huggedPillWidth(
            labelWidth: Double(title + icon),
            accessoryWidth: Double(shortcut + 48),
            min: Double(min),
            max: Double(max)
        ))
    }

    func update(tab: Tab, isActive: Bool) {
        status = tab.status
        isPersistent = tab.persistent
        titleLabel.stringValue = tabDisplayTitle(tab)
        setAgentIcon(for: tab)
        setPersistentIndicator(tab.persistent)
        setWorkingDotVisible(Self.isAgentWorking(tab))
        setAccessibilityLabel(Self.accessibilityLabel(tab))
        applyChrome(isActive: isActive)
    }

    /// Show/hide the leading "kept alive" pin (the visible form of `tab.persistent`).
    private func setPersistentIndicator(_ visible: Bool) {
        persistentIcon.isHidden = !visible
        persistentIconWidth.constant = visible ? 12 : 0
    }

    /// Show/hide the working dot and run its shuttle: a gentle glide between two spots —
    /// Ghostty's indeterminate-progress motion (easeInOut, 1.2s, autoreversing forever).
    /// Honors Reduce Motion: when enabled, the dot is shown statically without animation.
    private func setWorkingDotVisible(_ visible: Bool) {
        workingDot.isHidden = !visible
        if visible {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            if reduceMotion {
                // Static dot — remove any shuttle that may already be running.
                workingDot.layer?.removeAnimation(forKey: "shuttle")
            } else {
                guard workingDot.layer?.animation(forKey: "shuttle") == nil else { return }
                let anim = CABasicAnimation(keyPath: "transform.translation.x")
                anim.fromValue = -2.5
                anim.toValue = 2.5
                anim.duration = 1.2
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.autoreverses = true
                anim.repeatCount = .infinity
                workingDot.layer?.add(anim, forKey: "shuttle")
            }
        } else {
            workingDot.layer?.removeAnimation(forKey: "shuttle")
        }
    }

    /// Show the agent's brand glyph as a leading icon (tinted to its brand color)
    /// when one exists; collapse the slot otherwise.
    private func setAgentIcon(for tab: Tab) {
        if let kind = tabAgentKind(for: tab) {
            usesGenericIcon = false
            agentIcon.image = AgentIconRenderer.templateOrMonogramImage(for: kind, size: 14)
            agentIcon.contentTintColor = NSColor.fromHex(SessionCoordinator.shared.settings.agentColorHex(for: kind))
                ?? HarnessDesign.chrome.textSecondary
            agentIcon.isHidden = false
            agentIconWidth.constant = 14
        } else {
            usesGenericIcon = true
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            agentIcon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Terminal")?
                .withSymbolConfiguration(config)
            agentIcon.contentTintColor = HarnessDesign.chrome.textSecondary
            agentIcon.isHidden = false
            agentIconWidth.constant = 14
        }
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
        if usesGenericIcon {
            agentIcon.contentTintColor = isActive ? c.textPrimary : c.textSecondary
            agentIcon.appearance = NSAppearance(named: c.isDark ? .darkAqua : .aqua)
        }
        closeButton.contentTintColor = c.textTertiary
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        // Persistence pin reads as an intentional "kept alive" marker, so it carries the
        // brand accent rather than the neutral title color — visible on active and idle tabs alike.
        persistentIcon.contentTintColor = c.accent
        // Working dot follows the title color so it reads as part of the label, not a badge.
        workingDot.layer?.backgroundColor = titleLabel.textColor?.cgColor
        // ⌘N hint: a touch brighter on the active tab, quiet otherwise.
        shortcutLabel.textColor = isActive ? c.textSecondary : c.textTertiary
    }
}
