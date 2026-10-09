import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
final class ContentAreaViewController: NSViewController, TerminalTabBarDelegate {
    /// The session this window shows; set by `MainSplitViewController`.
    var context = WindowContext()

    /// A torn-off tab: onto another Harness window on the same machine, it joins that window's
    /// session; anywhere else it becomes a session of its own in a new window there.
    func tabBarDidTearOff(tabID: TabID, at screenPoint: NSPoint) {
        let coordinator = SessionCoordinator.shared
        let target = WindowContexts.frontmost(at: screenPoint)
        // Let go over its own window: the tab stays.
        if target === context { return }
        if let target, target.owner == context.owner, let session = target.sessionID {
            coordinator.moveTab(tabID, toSession: session) { id in
                if id != nil { target.window?.makeKeyAndOrderFront(nil) }
            }
            return
        }
        (NSApp.delegate as? AppDelegate)?.moveTabToNewWindow(tabID, at: screenPoint)
    }

    func tabBarDidReceivePane(_ surfaceID: SurfaceID, onTab tabID: TabID?) {
        SessionCoordinator.shared.dropPane(surfaceID, ontoTab: tabID)
    }

    private let tabBar = TerminalTabBarView()
    private let terminalHost = NSView()
    private var paneContainer: PaneContainerView?
    private let connectionNotice = NSStackView()
    private let connectionLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var lastStructureKey = ""
    private var pendingReload: Bool?
    /// Pasteboard change counter captured at left-mouse-down. On mouse-up, if it
    /// has incremented inside the terminal area AND the user has `copy-on-select`
    /// enabled, that means the renderer just copied the selection — surface a brief
    /// "Selection copied" toast.
    private var pasteboardCountAtMouseDown: Int = NSPasteboard.general.changeCount
    private var copySelectionMonitor: Any?

    override func loadView() {
        view = NSView()
        // The terminal area stays visually independent from app chrome. the renderer
        // owns its own background color, opacity, blur, and color pipeline here;
        // sidebar/tab chrome must not add an AppKit backdrop over or behind it.
        HarnessDesign.makeClear(view)
    }

    func applyChrome() {
        // One surface with the sidebar. An extra glass plate here made the
        // terminal a second background inside a frame.
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        refreshTerminalHostFill()
        tabBar.applyChrome()
        paneContainer?.applyChrome()
        // Density lives in the structure key, so a Comfortable/Compact change rebuilds
        // the islands instead of leaving the previous insets in place.
        reloadIfNeeded(force: false)
    }

    /// Back the terminal host so the canvas reads the same as the rest of the window.
    /// When the window is **opaque** (opacity ≥ 1) the host is a solid terminal-colored
    /// fill — this covers any resize gap before the renderer repaints, so the terminal
    /// shows true rich color. When **translucent** the host is `.clear`: the renderer
    /// already draws the canvas at `backgroundOpacity` alpha, so a clear host lets that
    /// single translucent layer composite over the one window-wide blur — exactly like
    /// the chrome (`sidebarBackground × opacity`). An opaque fill here would block the
    /// blur and make the terminal look solid while the chrome was see-through.
    private func refreshTerminalHostFill() {
        terminalHost.wantsLayer = true
        let settings = SessionCoordinator.shared.settings
        let opacity = CGFloat(ChromeMaterial.paintOpacity(
            stored: settings.backgroundOpacity,
            appearanceMode: settings.appearanceMode,
            systemAppearance: HarnessChrome.systemAppearance(from: view.effectiveAppearance)
        ))
        terminalHost.layer?.backgroundColor = opacity >= 1
            ? HarnessChrome.current.terminalBackground.cgColor
            : NSColor.clear.cgColor
    }

    /// Terminal under the tab row (title-bar mode) or at the top (sidebar mode, where the
    /// sidebar lists the tabs and the pane header sits on the traffic-light row).
    private lazy var hostBelowTabs = terminalHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
    private lazy var hostAtTop = terminalHost.topAnchor.constraint(equalTo: view.topAnchor)

    private var tabRowHidden = false

    func setTabRowHidden(_ hidden: Bool) {
        let changed = hidden != tabRowHidden
        tabRowHidden = hidden
        guard isViewLoaded else { return }   // viewDidLoad applies it
        applyTabRowConstraints()
        // The pane container pads its own top in sidebar mode, so its gutter fill covers it.
        if changed { reloadIfNeeded(force: true) }
    }

    private func applyTabRowConstraints() {
        tabBar.isHidden = tabRowHidden
        hostBelowTabs.isActive = !tabRowHidden
        hostAtTop.isActive = tabRowHidden
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        refreshTerminalHostFill()

        view.addSubview(tabBar)
        view.addSubview(terminalHost)

        NSLayoutConstraint.activate([
            // The tab row sits on the traffic-light line.
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // No divider line under the tab bar: the elevated chrome background now
            // provides the tab-strip/terminal boundary (see HarnessChromePalette).
            hostBelowTabs,
            terminalHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        applyTabRowConstraints()
        connectionNotice.orientation = .horizontal
        connectionNotice.spacing = 12
        connectionNotice.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        connectionNotice.wantsLayer = true
        connectionNotice.layer?.cornerRadius = 10
        connectionNotice.addArrangedSubview(connectionLabel)
        connectionNotice.addArrangedSubview(retryButton)
        connectionLabel.font = .systemFont(ofSize: 12)
        retryButton.target = self; retryButton.action = #selector(retryRemote)
        connectionNotice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(connectionNotice)
        NSLayoutConstraint.activate([
            connectionNotice.topAnchor.constraint(equalTo: terminalHost.topAnchor, constant: 10),
            connectionNotice.centerXAnchor.constraint(equalTo: terminalHost.centerXAnchor),
            connectionNotice.widthAnchor.constraint(lessThanOrEqualTo: terminalHost.widthAnchor, constant: -24),
        ])
        refreshConnectionNotice()

        installCopySelectionToast()
        reloadTabBar()
    }

    private func installCopySelectionToast() {
        copySelectionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown {
                self.pasteboardCountAtMouseDown = NSPasteboard.general.changeCount
            } else if event.type == .leftMouseUp,
                      SessionCoordinator.shared.settings.copyOnSelect,
                      self.eventIsInsideTerminalArea(event),
                      NSPasteboard.general.changeCount > self.pasteboardCountAtMouseDown
            {
                Toast.show("Selection copied", in: self.terminalHost)
            }
            return event
        }
    }

    private func eventIsInsideTerminalArea(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === view.window else { return false }
        let pointInHost = terminalHost.convert(event.locationInWindow, from: nil)
        return terminalHost.bounds.contains(pointInHost)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard paneContainer == nil || pendingReload != nil else { return }
        guard terminalHost.bounds.width > 1, terminalHost.bounds.height > 1 else { return }
        let force = pendingReload ?? true
        pendingReload = nil
        reloadIfNeeded(force: force)
    }

    /// The window's split controller calls this once per snapshot, after its context is
    /// current. Panes remount only when this window's own layout changed (the structure key),
    /// so a change in another window or on another machine leaves them alone.
    @objc private func retryRemote() { SessionCoordinator.shared.retryConnection(context.owner) }

    private func refreshConnectionNotice() {
        let state = SessionCoordinator.shared.connectionDescription(for: context.owner)
        connectionNotice.isHidden = context.owner == DaemonSidebar.localID || state == "Connected"
        connectionLabel.stringValue = "\(context.owner) · \(state) · Showing last output"
        connectionLabel.lineBreakMode = .byTruncatingTail
        retryButton.isEnabled = state == "Disconnected"
        connectionNotice.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        connectionNotice.layer?.backgroundColor = HarnessChrome.current.surfaceElevated.cgColor
    }

    func snapshotChanged(structureChanged: Bool, metadataOnly: Bool) {
        refreshConnectionNotice()
        if metadataOnly && !structureChanged {
            refreshTabBarMetadata()
            // A layout or ratio set elsewhere (`select-layout`, `rotate-window`, `resize-pane`)
            // keeps the same panes, so it arrives as metadata: the structure key (cheap to
            // build) remounts on a new arrangement and moves dividers in place otherwise.
            reloadIfNeeded(force: false)
            return
        }
        reloadTabBar()
        reloadIfNeeded(force: false)
    }

    func reloadTabBar() {
        let session = context.session
        tabBar.reload(tabs: session?.tabs ?? [], activeTabID: session?.activeTabID)
    }

    /// Leading inset so the tab row clears the macOS traffic lights when the sidebar is
    /// collapsed. Driven by `MainSplitViewController` during the toggle.
    func setTabBarLeadingInset(_ inset: CGFloat) {
        tabBar.setLeadingInset(inset)
    }

    func tabBarDidRequestSessions(from anchor: NSView) {
        SessionSwitcherController.toggle(relativeTo: view.window, anchor: anchor)
    }

    func showSessionSwitcher() {
        let anchor = tabBar.isHidden ? nil : tabBar.sessionsAnchor
        SessionSwitcherController.toggle(relativeTo: view.window, anchor: anchor)
    }

    func tabBarDidRequestToggleSidebar() {
        (view.window?.contentViewController as? MainSplitViewController)?.toggleSidebar()
    }

    func tabBarDidRequestPeek() {
        TabPeekController.toggle()
    }

    func refreshTabBarMetadata() {
        let session = context.session
        tabBar.refreshMetadata(tabs: session?.tabs ?? [], activeTabID: session?.activeTabID)
        paneContainer?.refreshHeaders()
    }

    func tabBarDidSelect(tabID: TabID) {
        guard let workspaceID = SessionCoordinator.shared.snapshot.activeWorkspaceID else { return }
        SessionCoordinator.shared.selectTab(workspaceID: workspaceID, tabID: tabID)
    }

    func tabBarDidRequestNewTab() {
        guard let workspaceID = SessionCoordinator.shared.snapshot.activeWorkspaceID else { return }
        SessionCoordinator.shared.addTab(to: workspaceID)
    }

    func tabBarDidRequestClose(tabID: TabID) {
        let coordinator = SessionCoordinator.shared
        guard let workspaceID = coordinator.snapshot.activeWorkspaceID else { return }
        if coordinator.snapshot.activeWorkspace?.activeTabID != tabID {
            coordinator.selectTab(workspaceID: workspaceID, tabID: tabID)
        }
        coordinator.closeActiveTabWithConfirmation()
    }

    func tabBarDidReorder(tabID: TabID, toIndex: Int) {
        guard let workspaceID = SessionCoordinator.shared.snapshot.activeWorkspaceID else { return }
        SessionCoordinator.shared.reorderTab(workspaceID: workspaceID, tabID: tabID, toIndex: toIndex)
    }

    func tabBarDidRequestCloseOthers(tabID: TabID) {
        SessionCoordinator.shared.closeOtherTabs(keeping: tabID)
    }

    func tabBarDidRequestRename(tabID: TabID) {
        let coordinator = SessionCoordinator.shared
        guard let workspaceID = coordinator.snapshot.activeWorkspaceID else { return }
        coordinator.selectTab(workspaceID: workspaceID, tabID: tabID)
        coordinator.beginRenameActiveTab()
    }

    func tabBarDidRequestSplit(tabID: TabID, direction: SplitDirection) {
        guard let workspaceID = SessionCoordinator.shared.snapshot.activeWorkspaceID else { return }
        SessionCoordinator.shared.splitTab(workspaceID: workspaceID, tabID: tabID, direction: direction)
    }

    func tabBarDidRequestTogglePersistent(tabID: TabID) {
        // Flip the tab's persistence pin via the daemon (mirrors the session pin in the sidebar).
        // Read the current value from the snapshot so the menu item toggles rather than forces a
        // state; the resulting commit refreshes the pill's checkmark on the next reload.
        let coordinator = SessionCoordinator.shared
        let current = coordinator.snapshot.workspaces
            .flatMap(\.sessions).flatMap(\.tabs)
            .first(where: { $0.id == tabID })?.persistent ?? false
        coordinator.requestDaemonAsync(.setTabPersistent(tabID: tabID, persistent: !current))
    }

    private func reloadAll(force: Bool) {
        reloadTabBar()
        reloadIfNeeded(force: force)
    }

    /// The tab (and zoom) the last layout showed, so only changes within it animate.
    private var lastAnimatedTab = ""

    func reloadIfNeeded(force: Bool) {
        guard terminalHost.bounds.width > 1, terminalHost.bounds.height > 1 else {
            pendingReload = (pendingReload ?? false) || force
            return
        }

        let coordinator = SessionCoordinator.shared
        guard let workspace = context.workspace, let tab = context.tab else { return }

        let displayNode = zoomedNode(for: tab) ?? tab.rootPane
        let density = "\(coordinator.settings.paneSpacing)|\(coordinator.settings.paneDensity.rawValue)|\(coordinator.settings.paneHeaders)|\(tabRowHidden)"
        let key = "\(density)|\(workspace.id)|\(tab.id)|\(tab.zoomedPaneID?.uuidString ?? "all")|\(paneKey(displayNode))"
        guard force || key != lastStructureKey else {
            // Same layout: only a ratio set elsewhere (`resize-pane`, Equalize Splits) can
            // differ, and it moves the dividers in place.
            paneContainer?.applyRatios(from: displayNode)
            return
        }
        // Only a pane added to or removed from the tab on screen animates; switching tabs or
        // zooming swaps the layout at once.
        let sameTab = lastAnimatedTab == "\(tab.id)|\(tab.zoomedPaneID?.uuidString ?? "")"
        lastAnimatedTab = "\(tab.id)|\(tab.zoomedPaneID?.uuidString ?? "")"
        let before = sameTab ? PaneTransitions.frames(of: paneContainer, in: terminalHost) : [:]
        lastStructureKey = key

        paneContainer?.removeFromSuperview()
        let container = PaneContainerView(
            tabID: tab.id,
            sidebarVisible: tabRowHidden,
            node: displayNode,
            cwd: tab.cwd,
            program: tab.currentCommand,
            agent: tab.agent?.kind.commandToken,
            themeName: context.snapshot.themeName
        )
        container.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: terminalHost.topAnchor),
            container.leadingAnchor.constraint(equalTo: terminalHost.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: terminalHost.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: terminalHost.bottomAnchor),
        ])
        paneContainer = container
        PaneTransitions.animate(from: before, into: container, in: terminalHost)
        // Re-assert the focused-pane border after the (re)mount — reused hosts keep
        // their flag, but a freshly shown tab needs its active pane established. Only the
        // window in front owns the app's active pane.
        if context.followsActiveSession { coordinator.ensureActivePane(for: tab) }
        // Arm the hover × (#168) only on multi-pane tabs — a single-pane tab already has the
        // tab close button, and the pane stays chrome-free at rest either way. Re-armed on
        // every structural (re)mount, so closing down to one pane disarms the survivor.
        let multiPane = tab.rootPane.allPaneIDs().count > 1
        for surfaceID in tab.rootPane.allSurfaceIDs() {
            coordinator.terminalHostIfExists(for: surfaceID)?.showsPaneCloseAffordance = multiPane
        }
    }

    private func paneKey(_ node: PaneNode) -> String {
        switch node {
        case let .leaf(leaf):
            return "l:\(leaf.surfaceID.uuidString)"
        case let .branch(direction, _, first, second):
            // Ratio is intentionally excluded from the rebuild key: a divider drag
            // persists the ratio but must not force a pane remount (that was the
            // resize flicker). Ratio is re-applied via setPosition on (re)mount.
            return "b:\(direction.rawValue):\(paneKey(first)):\(paneKey(second))"
        }
    }

    private func zoomedNode(for tab: Tab) -> PaneNode? {
        guard let zoomedPaneID = tab.zoomedPaneID else { return nil }
        return leafNode(paneID: zoomedPaneID, in: tab.rootPane)
    }

    private func leafNode(paneID: PaneID, in node: PaneNode) -> PaneNode? {
        switch node {
        case let .leaf(leaf) where leaf.id == paneID:
            return .leaf(leaf)
        case let .branch(_, _, first, second):
            return leafNode(paneID: paneID, in: first) ?? leafNode(paneID: paneID, in: second)
        default:
            return nil
        }
    }
}

@MainActor
final class PaneContainerView: NSView {
    private let coordinator = SessionCoordinator.shared
    private let tabID: TabID?
    private var islands: [PaneIslandView] = []

    init(tabID: TabID, sidebarVisible: Bool = false, node: PaneNode, cwd: String, program: String?, agent: String? = nil, themeName: String) {
        self.tabID = tabID
        super.init(frame: .zero)
        HarnessDesign.makeClear(self)
        let settings = SessionCoordinator.shared.settings
        let separated = settings.paneDensity.separatedIslands
        showsHeaders = separated && settings.paneHeaders
        // The root pads by half the gap; each island insets by the other half.
        let pad = ChromeLayout.containerPadding(separated: separated, padsTop: sidebarVisible, gap: settings.paneSpacing)
        // The sidebar supplies its own trailing spacing. Cancel the island's
        // leading inset here so its border meets the sidebar without a second gap.
        let leadingPadding = sidebarVisible
            ? -ChromeLayout.cardInsets(separated: separated, gap: coordinator.settings.paneSpacing).leading
            : pad.leading
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: CGFloat(pad.top)),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CGFloat(leadingPadding)),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CGFloat(pad.trailing)),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -CGFloat(pad.bottom)),
        ])
        build(node: node, cwd: cwd, program: program, agent: agent, into: content, separated: separated)
        refreshHeaders()
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeSurfaceDidChange),
            name: .harnessActiveSurfaceDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(activeSurfaceDidChange),
            name: .harnessSizeOwnershipDidChange, object: nil
        )
    }

    @objc private func activeSurfaceDidChange() {
        refreshHeaders()
        announceFocusedPane()
    }

    /// Each pane's card frame, in `space`'s coordinates.
    func islandFrames(in space: NSView) -> [SurfaceID: NSRect] {
        Dictionary(islands.map { ($0.surfaceID, space.convert($0.bounds, from: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    func island(for surfaceID: SurfaceID) -> PaneIslandView? {
        islands.first { $0.surfaceID == surfaceID }
    }

    private var showsHeaders = false
    private var announcedSurface: SurfaceID?

    /// Re-read each pane's identity and focus into its header and its VoiceOver label.
    func refreshHeaders() {
        guard let tabID, let tab = coordinator.tab(tabID) else { return }
        let leaves = tab.rootPane.allLeaves()
        let focused = coordinator.activeSurfaceID
        for island in islands {
            guard let index = leaves.firstIndex(where: { $0.surfaceID == island.surfaceID }) else { continue }
            let identity = PaneIdentity.of(leaf: leaves[index], in: tab)
            let title = SurfaceIdentity.label(directory: identity.directory, program: identity.program, agent: identity.agent?.commandToken)
            let isFocused = leaves.count == 1 || island.surfaceID == focused
            island.terminalHost?.setAccessibilityLabel(
                "Pane \(index + 1) of \(leaves.count), \(title)" + (isFocused && leaves.count > 1 ? ", focused" : "")
            )
            guard showsHeaders, let header = island.header else { continue }
            header.update(title: title, agent: identity.agent, focused: isFocused, ownership: island.terminalHost?.sizeOwnership)
        }
    }

    /// Tell VoiceOver which pane now has focus when it moves between split panes.
    private func announceFocusedPane() {
        guard let focused = coordinator.activeSurfaceID, focused != announcedSurface,
              let host = islands.first(where: { $0.surfaceID == focused })?.terminalHost,
              let label = host.accessibilityLabel(), islands.count > 1
        else { return }
        announcedSurface = focused
        NSAccessibility.post(element: host, notification: .announcementRequested, userInfo: [
            .announcement: label, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// Paints the gutter around the islands. When the window is translucent nothing else
    /// paints there (the islands' drawables carry their own alpha), so without this the gaps
    /// were holes straight through to the desktop.
    private let gapFill = CAShapeLayer()

    func applyChrome() {
        HarnessDesign.makeClear(self)
        for island in islands {
            island.applyChrome()
        }
        updateGapFill()
    }

    override func layout() {
        super.layout()
        updateGapFill()
        updateCornerHandles()
    }

    // MARK: - Corner handles

    private var cornerHandles: [SplitCornerHandle] = []

    /// One handle per place two perpendicular dividers meet, kept on top of the panes.
    private func updateCornerHandles() {
        let splits = descendants(of: self).compactMap { $0 as? HarnessSplitView }
        let junctions = SplitCornerHandle.junctions(of: splits, in: self)
        while cornerHandles.count > junctions.count { cornerHandles.removeLast().removeFromSuperview() }
        while cornerHandles.count < junctions.count {
            let handle = SplitCornerHandle(frame: .zero)
            addSubview(handle, positioned: .above, relativeTo: nil)
            cornerHandles.append(handle)
        }
        for (handle, junction) in zip(cornerHandles, junctions) {
            handle.across = junction.across
            handle.along = junction.along
            if handle.frame != junction.frame {
                handle.frame = junction.frame
                window?.invalidateCursorRects(for: handle)
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Fill = the container minus each island's rounded rect, in the chrome color at the
    /// window's paint opacity, so the gutter matches the tab row and the sidebar.
    func updateGapFill() {
        guard let layer else { return }
        if gapFill.superlayer !== layer {
            layer.insertSublayer(gapFill, at: 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gapFill.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        for island in islands where island.superview != nil {
            // The hole stops one point inside the card, under its hairline, so the two
            // antialiased edges never share a pixel and leave a see-through seam.
            let overlap = island.layer?.borderWidth ?? 0
            let rect = convert(island.bounds, from: island).insetBy(dx: overlap, dy: overlap)
            guard rect.width > 0, rect.height > 0 else { continue }
            let radius = max(0, min((island.layer?.cornerRadius ?? 0) - overlap, rect.width / 2, rect.height / 2))
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        gapFill.path = path
        gapFill.fillRule = .evenOdd
        let c = HarnessChrome.current
        gapFill.fillColor = c.sidebarBackground.withAlphaComponent(HarnessChrome.paintOpacity).cgColor
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // refreshChrome(snapshot:) was removed: its `if let match, let host` body was completely
    // empty — the loop did nothing.  See the comment above reloadIfNeeded for context.
    //
    // tabFor(surfaceID:in:) was also removed: it was only used by refreshChrome.

    private func build(node: PaneNode, cwd: String, program: String?, agent: String?, into parent: NSView, separated: Bool) {
        switch node {
        case let .leaf(leaf):
            let host = coordinator.terminalHost(for: leaf.surfaceID, cwd: cwd)
            let island = PaneIslandView(surfaceID: leaf.surfaceID, separated: separated, showsHeader: showsHeaders)
            island.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(island)
            let insets = ChromeLayout.cardInsets(separated: separated, gap: coordinator.settings.paneSpacing)
            NSLayoutConstraint.activate([
                island.topAnchor.constraint(equalTo: parent.topAnchor, constant: CGFloat(insets.top)),
                island.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: CGFloat(insets.leading)),
                island.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -CGFloat(insets.trailing)),
                island.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -CGFloat(insets.bottom)),
            ])
            island.embed(host)
            islands.append(island)
        case let .branch(direction, ratio, firstNode, secondNode):
            let split = HarnessSplitView()
            split.dividerStyle = .thin
            split.isVertical = direction == .horizontal
            split.preferredRatio = CGFloat(ratio)
            split.tabID = tabID
            split.firstPaneID = firstLeafID(firstNode)
            split.secondPaneID = firstLeafID(secondNode)
            split.delegate = split
            let first = NSView()
            let second = NSView()
            // A new pane's fitting size is a few lines. Low hugging lets the split
            // give it the rest of the column instead of leaving an empty band.
            for pane in [first, second] {
                pane.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
                pane.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
                pane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                pane.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            }
            split.addSubview(first)
            split.addSubview(second)
            split.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(split)
            NSLayoutConstraint.activate([
                split.topAnchor.constraint(equalTo: parent.topAnchor),
                split.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                split.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
            // Build the child panes first, then set the divider — so each child lays out once
            // at ~final bounds instead of resizing (and re-sizing its PTY) twice.
            // Comfortable separates with the island inset. Compact stays flush; its
            // divider is the 1pt border and does not also inset the island.
            build(node: firstNode, cwd: cwd, program: program, agent: agent, into: first, separated: separated)
            build(node: secondNode, cwd: cwd, program: program, agent: agent, into: second, separated: separated)
            // [weak split]: rapid tab switching can tear down this PaneContainerView before the
            // async fires, leaving `split` pointing at a detached view with stale bounds — a
            // no-op setPosition call that can confuse AppKit's divider accounting on the new
            // container. The explicit bounds check below guards the case where layout hasn't
            // run yet (zero-size container), which would force the divider to one edge.
            DispatchQueue.main.async { [weak split] in
                guard let split, split.bounds.width > 1, split.bounds.height > 1 else { return }
                let position = (direction == .horizontal ? split.frame.width : split.frame.height) * ratio
                if position > 50 {
                    split.setPosition(position, ofDividerAt: 0)
                }
            }
        }
    }

    /// Move dividers whose ratio changed outside this window, without a remount. A split
    /// being dragged, or with its own drag still saving, is left alone.
    func applyRatios(from node: PaneNode) {
        var wanted: [String: Double] = [:]
        func collect(_ node: PaneNode) {
            guard case let .branch(_, ratio, first, second) = node else { return }
            if let a = firstLeafID(first), let b = firstLeafID(second) { wanted["\(a)|\(b)"] = ratio }
            collect(first)
            collect(second)
        }
        collect(node)
        guard NSEvent.pressedMouseButtons == 0 else { return }
        func visit(_ view: NSView) {
            if let split = view as? HarnessSplitView, !split.isSavingRatio,
               let a = split.firstPaneID, let b = split.secondPaneID, let ratio = wanted["\(a)|\(b)"] {
                split.adopt(ratio: CGFloat(ratio))
            }
            view.subviews.forEach(visit)
        }
        visit(self)
    }

    /// Representative leaf of a subtree (its first leaf in traversal order). Paired
    /// across both children, it uniquely identifies a branch for ratio persistence.
    private func firstLeafID(_ node: PaneNode) -> PaneID? {
        switch node {
        case let .leaf(leaf): return leaf.id
        case let .branch(_, _, first, _): return firstLeafID(first)
        }
    }
}

/// Rounded terminal island: an optional title row over the terminal host.
@MainActor
final class PaneIslandView: NSView {
    private(set) weak var terminalHost: TerminalHostView?
    private let separated: Bool
    let surfaceID: SurfaceID
    /// Title row, present on comfortable panes when pane headers are on.
    private(set) var header: PaneHeaderView?

    init(surfaceID: SurfaceID, separated: Bool, showsHeader: Bool) {
        self.separated = separated
        self.surfaceID = surfaceID
        super.init(frame: .zero)
        wantsLayer = true
        let chrome = ChromeLayout.island(separated: separated, splitRadius: Double(HarnessDesign.Radius.overlay))
        layer?.cornerRadius = CGFloat(chrome.cornerRadius)
        // Circular, not continuous: the gutter fill cuts its holes with CGPath rounded
        // rects (circular arcs), and the two edges must be the same curve or the corners
        // show slivers of the desktop.
        layer?.cornerCurve = .circular
        layer?.masksToBounds = chrome.cornerRadius > 0
        // A separated island carries a hairline so it reads as a card against the
        // gutter, which is painted in the same chrome color.
        layer?.borderWidth = separated ? 1 : 0
        if showsHeader {
            let header = PaneHeaderView(surfaceID: surfaceID)
            header.translatesAutoresizingMaskIntoConstraints = false
            addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: topAnchor),
                header.leadingAnchor.constraint(equalTo: leadingAnchor),
                header.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
            self.header = header
        }
        registerForDraggedTypes([PaneDrag.type])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Pane drops

    private var dropHighlight: PaneDropHighlightView?

    private func dropZone(_ info: NSDraggingInfo) -> PaneDropZone? {
        guard let source = PaneDrag.surfaceID(in: info), source != surfaceID,
              SessionCoordinator.shared.sameMachine(source, surfaceID)
        else { return nil }
        return PaneDropZone.at(convert(info.draggingLocation, from: nil), in: bounds)
    }

    private func showDrop(_ zone: PaneDropZone?) -> NSDragOperation {
        guard let zone else {
            dropHighlight?.removeFromSuperview()
            dropHighlight = nil
            return []
        }
        if dropHighlight == nil {
            let highlight = PaneDropHighlightView(frame: bounds)
            highlight.autoresizingMask = [.width, .height]
            addSubview(highlight, positioned: .above, relativeTo: nil)
            dropHighlight = highlight
        }
        dropHighlight?.zone = zone
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { showDrop(dropZone(sender)) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { showDrop(dropZone(sender)) }
    override func draggingExited(_ sender: NSDraggingInfo?) { _ = showDrop(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { _ = showDrop(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let zone = dropZone(sender)
        _ = showDrop(nil)
        guard let zone, let source = PaneDrag.surfaceID(in: sender) else { return false }
        SessionCoordinator.shared.dropPane(source, onto: surfaceID, zone: zone)
        return true
    }

    func embed(_ host: NSView) {
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: header?.bottomAnchor ?? topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let host = host as? TerminalHostView {
            terminalHost = host
            let radius = ChromeLayout.island(separated: separated, splitRadius: Double(HarnessDesign.Radius.overlay)).cornerRadius
            host.applyIslandCornerRadius(CGFloat(radius))
        }
    }

    override func layout() {
        super.layout()
        // A divider drag resizes islands without laying out the container.
        enclosingContainer?.updateGapFill()
    }

    private var enclosingContainer: PaneContainerView? {
        var view = superview
        while let current = view {
            if let container = current as? PaneContainerView { return container }
            view = current.superview
        }
        return nil
    }

    func applyChrome() {
        let c = HarnessChrome.current
        let settings = SessionCoordinator.shared.settings
        let appearance = HarnessChrome.systemAppearance(from: effectiveAppearance)
        let backdropAlpha = CGFloat(ChromeMaterial.backdropFillAlpha(
            stored: settings.backgroundOpacity,
            appearanceMode: settings.appearanceMode,
            systemAppearance: appearance
        ))
        let hairline = (c.borderStrong.usingColorSpace(.sRGB) ?? c.borderStrong)
        layer?.borderColor = hairline.cgColor
        layer?.backgroundColor = c.terminalBackground.withAlphaComponent(backdropAlpha).cgColor
        // The header has no drawable behind it, so it paints the canvas itself at the
        // same opacity the terminal composites at.
        let headerAlpha = CGFloat(ChromeMaterial.headerFillAlpha(
            stored: settings.backgroundOpacity,
            appearanceMode: settings.appearanceMode,
            systemAppearance: appearance
        ))
        header?.applyChrome()
        header?.layer?.backgroundColor = c.terminalBackground.withAlphaComponent(headerAlpha).cgColor
        if let host = terminalHost {
            let radius = ChromeLayout.island(separated: separated, splitRadius: Double(HarnessDesign.Radius.overlay)).cornerRadius
            host.applyIslandCornerRadius(CGFloat(radius))
        }
    }
}

/// NSSplitView for terminal panes. The divider is a gap, not a hairline: each child is a
/// rounded island, and the clear divider lets the window material show between them.
/// Drags still persist so split ratios survive relaunch. Acts as its own delegate.
@MainActor
final class HarnessSplitView: NSSplitView, NSSplitViewDelegate {
    var tabID: TabID?
    var firstPaneID: PaneID?
    var secondPaneID: PaneID?
    /// Share of the free length given to the first pane when AppKit leaves a gap.
    var preferredRatio: CGFloat = 0.5
    private var ratioDebounce: DispatchWorkItem?
    private var tiling = false

    /// A drag's ratio is on its way to the daemon: the snapshot may still hold the old one.
    var isSavingRatio: Bool { ratioDebounce != nil }

    /// Move the divider to `ratio` when it's visibly elsewhere.
    func adopt(ratio: CGFloat) {
        guard subviews.count >= 2 else { return }
        let length = isVertical ? bounds.width : bounds.height
        guard length > 50 else { return }
        let current = (isVertical ? subviews[0].frame.width : subviews[0].frame.height) / length
        guard abs(current - ratio) > 0.01 else { return }
        preferredRatio = ratio
        setPosition(length * ratio, ofDividerAt: 0)
    }

    override var dividerColor: NSColor { .clear }

    /// AppKit can leave a 0-pt divider's panes at their fitting size, which shows
    /// as an empty band. Tile them so the two panes cover the split.
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        if tiling {
            super.resizeSubviews(withOldSize: oldSize)
            return
        }
        super.resizeSubviews(withOldSize: oldSize)
        guard subviews.count == 2, bounds.width > 1, bounds.height > 1 else { return }
        let across = isVertical
        let total = across ? bounds.width : bounds.height
        let thickness = dividerThickness
        let covered = subviews.reduce(CGFloat(0)) {
            $0 + (across ? $1.frame.width : $1.frame.height)
        }
        if total - covered - thickness <= 1 {
            if total > 0 {
                let first = across ? subviews[0].frame.width : subviews[0].frame.height
                preferredRatio = first / total
            }
            return
        }
        let tiled = ChromeLayout.tiledSplit(
            length: Double(total),
            thickness: Double(thickness),
            ratio: Double(preferredRatio)
        )
        tiling = true
        if across {
            subviews[0].frame = NSRect(x: 0, y: 0, width: tiled.first, height: bounds.height)
            subviews[1].frame = NSRect(x: tiled.secondOrigin, y: 0, width: tiled.second, height: bounds.height)
        } else {
            subviews[0].frame = NSRect(x: 0, y: bounds.height - tiled.first, width: bounds.width, height: tiled.first)
            subviews[1].frame = NSRect(x: 0, y: 0, width: bounds.width, height: tiled.second)
        }
        tiling = false
    }

    /// Comfortable's gap is the island inset. The divider stays 0 so it does not
    /// add a second gap. Compact is the 1pt border.
    override var dividerThickness: CGFloat {
        CGFloat(SessionCoordinator.shared.settings.paneDensity.splitDividerPoints)
    }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        // Widen the interactive/cursor zone past the 1px thin divider. NSSplitView
        // shows the resize cursor over the effective rect, so this covers the cursor.
        var rect = proposedEffectiveRect
        let hit = max(dividerThickness, 8)
        if isVertical { rect.size.width = hit } else { rect.size.height = hit }
        return rect
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        // The divider-index key is present only when the user dragged a divider —
        // skip programmatic setPosition and window/layout resizes.
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        saveRatio()
        // A divider drag moves the corner handles where it meets another divider.
        var view = superview
        while let current = view, !(current is PaneContainerView) { view = current.superview }
        view?.needsLayout = true
    }

    /// Save the divider's position as this split's ratio (debounced), as a drag does.
    func saveRatio() {
        guard let tabID, let firstPaneID, let secondPaneID, subviews.count >= 2 else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 1 else { return }
        let firstSize = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        let ratio = Double(firstSize / total)
        // Coalesce the stream of drag events into one write after the drag settles.
        ratioDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.ratioDebounce = nil
                SessionCoordinator.shared.setSplitRatio(
                    tabID: tabID,
                    firstPaneID: firstPaneID,
                    secondPaneID: secondPaneID,
                    ratio: ratio
                )
            }
        }
        ratioDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}
