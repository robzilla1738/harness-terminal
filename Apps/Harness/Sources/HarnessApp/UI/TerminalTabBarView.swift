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
}

extension TerminalTabBarDelegate {
    func tabBarDidRequestClose(tabID: TabID) {}
    func tabBarDidReorder(tabID: TabID, toIndex: Int) {}
    func tabBarDidRequestCloseOthers(tabID: TabID) {}
    func tabBarDidRequestRename(tabID: TabID) {}
    func tabBarDidRequestSplit(tabID: TabID, direction: SplitDirection) {}
}

enum TabContextCommand {
    case close
    case closeOthers
    case rename
    case splitHorizontal
    case splitVertical
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

    // Layout metrics.
    private let edgeInset: CGFloat = 10
    private let pillSpacing = HarnessDesign.Spacing.xs
    private let buttonSize: CGFloat = 24
    private let minPillWidth: CGFloat = 72
    private let maxPillWidth: CGFloat = 200

    /// Extra leading inset so the tab strip clears the macOS traffic lights when the
    /// sidebar is collapsed (content shifts to x=0 under `.fullSizeContentView`). 0
    /// when the sidebar is visible. Driven (and animated) by the split controller.
    var leadingInset: CGFloat = 0 {
        didSet { guard leadingInset != oldValue else { return }; needsLayout = true }
    }

    /// Leading x for all tab pills / buttons (rides the traffic-light inset). The
    /// sidebar toggle now lives in the sidebar header, so nothing precedes the pills.
    private var contentLeft: CGFloat { edgeInset + leadingInset }

    // Drag-reorder state.
    private weak var draggingPill: TabPillView?
    private var dragGrabOffsetX: CGFloat = 0
    private var dragTargetIndex: Int?
    private var visibleStart = 0
    private var visibleCount = 0
    private var currentPillWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        HarnessDesign.applyTabBarChrome(to: self)

        newTabButton.setSymbol("plus", accessibilityDescription: "New tab", pointSize: 11, weight: .medium)
        newTabButton.toolTip = "New tab (⌘T)"
        newTabButton.target = self
        newTabButton.action = #selector(addNewTab)
        newTabButton.translatesAutoresizingMaskIntoConstraints = true
        addSubview(newTabButton)

        overflowButton.setSymbol("chevron.down", accessibilityDescription: "More tabs", pointSize: 11, weight: .medium)
        overflowButton.toolTip = "More tabs"
        overflowButton.target = self
        overflowButton.action = #selector(showOverflowMenu)
        overflowButton.translatesAutoresizingMaskIntoConstraints = true
        overflowButton.isHidden = true
        addSubview(overflowButton)

        let height = heightAnchor.constraint(equalToConstant: HarnessDesign.tabBarHeight)
        height.priority = .defaultHigh
        height.isActive = true
    }

    func reload(tabs: [Tab], activeTabID: TabID?) {
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
        guard draggingPill == nil else { return } // drag drives its own positioning
        layoutPills()
    }

    private func layoutPills() {
        let count = orderedPills.count
        let buttonY = (bounds.height - buttonSize) / 2
        guard count > 0 else {
            newTabButton.frame = NSRect(x: contentLeft, y: buttonY, width: buttonSize, height: buttonSize)
            overflowButton.isHidden = true
            return
        }

        // Try to fit every pill inline alongside the "+" button.
        let inlineAvail = bounds.width - contentLeft - edgeInset - buttonSize - pillSpacing
        var pillWidth = min(maxPillWidth, (inlineAvail - pillSpacing * CGFloat(count - 1)) / CGFloat(count))

        var needsOverflow = false
        var vCount = count
        if pillWidth < minPillWidth {
            // Can't fit all even at minimum width — reserve the overflow button too.
            needsOverflow = true
            let avail = bounds.width - contentLeft - edgeInset - buttonSize * 2 - pillSpacing * 2
            vCount = min(count, max(1, Int((avail + pillSpacing) / (minPillWidth + pillSpacing))))
            pillWidth = max(minPillWidth, (avail - pillSpacing * CGFloat(vCount - 1)) / CGFloat(vCount))
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
        currentPillWidth = pillWidth

        let y = (bounds.height - HarnessDesign.tabPillHeight) / 2
        var x = contentLeft
        for (i, pill) in orderedPills.enumerated() {
            let visible = i >= start && i < start + vCount
            pill.isHidden = !visible
            guard visible else { continue }
            pill.frame = NSRect(x: x, y: y, width: pillWidth, height: HarnessDesign.tabPillHeight)
            x += pillWidth + pillSpacing
        }
        newTabButton.frame = NSRect(x: x, y: buttonY, width: buttonSize, height: buttonSize)

        overflowButton.isHidden = !needsOverflow
        if needsOverflow {
            overflowButton.frame = NSRect(x: bounds.width - edgeInset - buttonSize, y: buttonY, width: buttonSize, height: buttonSize)
        }
    }

    private func slotX(_ slot: Int) -> CGFloat {
        contentLeft + CGFloat(slot) * (currentPillWidth + pillSpacing)
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
        let pitch = currentPillWidth + pillSpacing
        let raw = pitch > 0 ? (dragged.frame.minX - contentLeft) / pitch : 0
        let target = max(0, min(Int(raw.rounded()), visible.count - 1))
        dragTargetIndex = visibleStart + target

        let y = (bounds.height - HarnessDesign.tabPillHeight) / 2
        var oi = 0
        HarnessMotion.animate(HarnessDesign.Motion.fast) { _ in
            for slot in 0..<visible.count where slot != target {
                guard oi < others.count else { break }
                let pill = others[oi]; oi += 1
                pill.animator().frame = NSRect(x: self.slotX(slot), y: y, width: self.currentPillWidth, height: HarnessDesign.tabPillHeight)
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
        }
    }

    @objc private func showOverflowMenu() {
        let menu = NSMenu()
        for (i, tab) in tabs.enumerated() where !(i >= visibleStart && i < visibleStart + visibleCount) {
            let item = NSMenuItem(title: tabDisplayTitle(tab), action: #selector(overflowItemSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tab.id.uuidString
            item.state = tab.status == .waiting ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: overflowButton.frame.minX, y: overflowButton.frame.minY), in: self)
    }

    @objc private func overflowItemSelected(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        delegate?.tabBarDidSelect(tabID: id)
    }
}

/// Display label shared by pills and the overflow menu. When an agent has a brand
/// icon, the pill shows that icon as a leading glyph + the folder, so the title is
/// just the folder (e.g. "harness"). Agents without an icon keep "folder · Agent"
/// so they're still identifiable. Otherwise: folder, then a custom shell title.
@MainActor
private func tabDisplayTitle(_ tab: Tab) -> String {
    let folder = HarnessDesign.pathDisplayName(tab.cwd)
    if let kind = tabAgentKind(for: tab) {
        if AgentIconRenderer.hasIcon(for: kind) {
            return folder.isEmpty ? kind.displayName : folder
        }
        return folder.isEmpty ? kind.displayName : "\(folder) · \(kind.displayName)"
    }
    let titleIsAgentBranding = !tab.title.isEmpty && AgentTitleInference.kind(from: tab.title) != nil
    let hasCustomTitle = !tab.title.isEmpty && tab.title != "Shell" && !titleIsAgentBranding
    return !folder.isEmpty ? folder : (hasCustomTitle ? tab.title : "Terminal")
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
    /// Ghostty-style "AI is working" indicator: a tiny dot before the title that discretely
    /// shuttles between two spots while the tab's agent is producing output. Hidden otherwise.
    private let workingDot = NSView()
    /// ⌘N hint, shown at the trailing edge for the first 9 tabs and
    /// swapped for the close button on hover. Empty for tabs past position 9.
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hasShortcut: Bool
    private var agentIconWidth: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var isActive = false
    private var isHovered = false
    private var status: TabStatus = .idle

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

        wantsLayer = true
        // Card radius (not control) so the active pill reads identically to the
        // selected session card in the sidebar.
        layer?.cornerRadius = HarnessDesign.Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        titleLabel.font = HarnessDesign.Typography.tabTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        titleLabel.stringValue = tabDisplayTitle(tab)
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

        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        shortcutLabel.alignment = .right
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.stringValue = position.map { "⌘\($0)" } ?? ""
        shortcutLabel.isHidden = !hasShortcut
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)

        workingDot.wantsLayer = true
        workingDot.layer?.cornerRadius = 1
        workingDot.translatesAutoresizingMaskIntoConstraints = false
        workingDot.isHidden = true

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
        let titleLeading = titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: agentIcon.trailingAnchor, constant: 4)
        let closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.xs)
        let closeWidth = closeButton.widthAnchor.constraint(equalToConstant: 14)
        let closeHeight = closeButton.heightAnchor.constraint(equalToConstant: 14)
        [titleLeading, closeTrailing, closeWidth, closeHeight].forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            agentIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.Spacing.sm),
            agentIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            agentIcon.heightAnchor.constraint(equalToConstant: 14),
            agentIconWidth,
            titleLeading,
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -HarnessDesign.Spacing.xs),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -HarnessDesign.Spacing.xs),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.sm),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeTrailing,
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeWidth,
            closeHeight,
            // Working dot sits just before the title, Ghostty-style ("· title"). Overlay only —
            // it never affects the centered title layout; the shuttle animation gives it room.
            workingDot.trailingAnchor.constraint(equalTo: titleLabel.leadingAnchor, constant: -7),
            workingDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            workingDot.widthAnchor.constraint(equalToConstant: 2),
            workingDot.heightAnchor.constraint(equalToConstant: 2),
        ])

        setAgentIcon(for: tab)
        setWorkingDotVisible(Self.isAgentWorking(tab))
        applyChrome(isActive: isActive)
    }

    /// Primary signal: a live OSC 9;4 progress report — terminal-native, exactly what Ghostty
    /// renders (Claude Code 2.0+ keep-alives one across each full turn, including thinking).
    /// Fallback: the process detector's output recency, for agents that don't emit 9;4 (codex).
    /// `waiting` only vetoes the fallback — an explicit progress report outranks a stale
    /// waiting status.
    private static func isAgentWorking(_ tab: Tab) -> Bool {
        if tab.rootPane.allSurfaceIDs().contains(where: { SurfaceProgressTracker.shared.isActive($0) }) {
            return true
        }
        return tab.agent?.activity == .working && tab.status != .waiting
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
        HarnessMotion.animate(HarnessDesign.Motion.microFast) { _ in
            closeButton.animator().alphaValue = 1
            shortcutLabel.animator().alphaValue = 0
            applyChrome(isActive: isActive)
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        HarnessMotion.animate(HarnessDesign.Motion.microFast) { _ in
            closeButton.animator().alphaValue = 0
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

    @objc private func closeClicked() {
        onClose?(tabID)
    }

    func update(tab: Tab, isActive: Bool) {
        status = tab.status
        titleLabel.stringValue = tabDisplayTitle(tab)
        setAgentIcon(for: tab)
        setWorkingDotVisible(Self.isAgentWorking(tab))
        applyChrome(isActive: isActive)
    }

    /// Show/hide the working dot and run its shuttle: a gentle glide between two spots —
    /// Ghostty's indeterminate-progress motion (easeInOut, 1.2s, autoreversing forever).
    private func setWorkingDotVisible(_ visible: Bool) {
        workingDot.isHidden = !visible
        if visible {
            guard workingDot.layer?.animation(forKey: "shuttle") == nil else { return }
            let anim = CABasicAnimation(keyPath: "transform.translation.x")
            anim.fromValue = -2.5
            anim.toValue = 2.5
            anim.duration = 1.2
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            anim.autoreverses = true
            anim.repeatCount = .infinity
            workingDot.layer?.add(anim, forKey: "shuttle")
        } else {
            workingDot.layer?.removeAnimation(forKey: "shuttle")
        }
    }

    /// Show the agent's brand glyph as a leading icon (tinted to its brand color)
    /// when one exists; collapse the slot otherwise.
    private func setAgentIcon(for tab: Tab) {
        if let kind = tabAgentKind(for: tab), let icon = AgentIconRenderer.templateImage(for: kind, size: 14) {
            agentIcon.image = icon
            agentIcon.contentTintColor = NSColor.fromHex(SessionCoordinator.shared.settings.agentColorHex(for: kind))
                ?? HarnessDesign.chrome.textSecondary
            agentIcon.isHidden = false
            agentIconWidth.constant = 14
        } else {
            agentIcon.image = nil
            agentIcon.isHidden = true
            agentIconWidth.constant = 0
        }
    }

    func applyChrome(isActive: Bool) {
        self.isActive = isActive
        let c = HarnessDesign.chrome
        layer?.cornerRadius = HarnessDesign.Radius.card

        // The active tab is painted to match the *selected session card* in the sidebar
        // exactly (SessionCardRowView.refresh): an accent-tinted fill + accent rim +
        // resting elevation, so the tab strip and the side tab read as one system.
        if isActive {
            layer?.backgroundColor = c.accent.withAlphaComponent(c.isDark ? 0.13 : 0.10).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = c.focusRing.withAlphaComponent(c.isDark ? 0.48 : 0.52).cgColor
            HarnessDesign.applyShadow(.elevation1, to: layer)
            titleLabel.textColor = c.textPrimary
        } else if isHovered {
            layer?.backgroundColor = c.rowHoverFill.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            HarnessDesign.applyShadow(.none, to: layer)
            titleLabel.textColor = c.textPrimary
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            layer?.borderColor = NSColor.clear.cgColor
            HarnessDesign.applyShadow(.none, to: layer)
            titleLabel.textColor = c.textSecondary
        }

        closeButton.contentTintColor = c.textTertiary
        closeButton.layer?.backgroundColor = NSColor.clear.cgColor
        // Working dot follows the title color so it reads as part of the label, not a badge.
        workingDot.layer?.backgroundColor = titleLabel.textColor?.cgColor
        // ⌘N hint: a touch brighter on the active tab, quiet otherwise.
        shortcutLabel.textColor = isActive ? c.textSecondary : c.textTertiary
    }
}
