import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
final class ContentAreaViewController: NSViewController, TerminalTabBarDelegate {
    private let titleStrip = WindowTitleStripView()
    private let tabBar = TerminalTabBarView()
    private let terminalHost = NSView()
    private var paneContainer: PaneContainerView?
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
        titleStrip.applyColors()
        tabBar.applyChrome()
        paneContainer?.applyChrome()
        // Density lives in the structure key, so a Comfortable/Compact change rebuilds
        // the islands instead of leaving the previous insets in place.
        reloadIfNeeded(force: false)
    }

    /// The title strip is only a window-drag handle. The tab already shows the
    /// directory, so nothing under the tab repeats it.
    private func updateTitleStripPath() {
        titleStrip.setIdentity("")
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

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        refreshTerminalHostFill()

        titleStrip.isHidden = true
        view.addSubview(titleStrip)
        view.addSubview(tabBar)
        view.addSubview(terminalHost)

        NSLayoutConstraint.activate([
            // Draggable title strip above the tabs: window-move grab area + Ghostty-style
            // folder/path readout. Pushes the tab pills below the traffic-light band.
            titleStrip.topAnchor.constraint(equalTo: view.topAnchor),
            titleStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The tab row sits on the traffic-light line. The old strip above it was empty space.
            titleStrip.heightAnchor.constraint(equalToConstant: 0),

            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            // No divider line under the tab bar: the elevated chrome background now
            // provides the tab-strip/terminal boundary (see HarnessChromePalette).
            terminalHost.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            terminalHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminalHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(snapshotChanged(_:)),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
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

    @objc private func snapshotChanged(_ note: Notification) {
        let structureChanged = note.userInfo?["structureChanged"] as? Bool ?? true
        let metadataOnly = note.userInfo?["metadataOnly"] as? Bool ?? false
        if metadataOnly && !structureChanged {
            refreshTabBarMetadata()
            return
        }
        reloadTabBar()
        reloadIfNeeded(force: structureChanged)
    }

    func reloadTabBar() {
        let snap = SessionCoordinator.shared.snapshot
        tabBar.reload(tabs: snap.activeWorkspace?.tabs ?? [], activeTabID: snap.activeWorkspace?.activeTabID)
        updateTitleStripPath()
    }

    /// Leading inset so the title strip's path readout clears the macOS traffic lights when
    /// the sidebar is collapsed. Driven by `MainSplitViewController` during the toggle. The
    /// tab bar itself sits below the lights (the strip pushes it down) and needs no inset.
    func setTabBarLeadingInset(_ inset: CGFloat) {
        tabBar.setLeadingInset(inset)
        tabBar.setSidebarCollapsed(inset > 1)
    }

    func tabBarDidRequestToggleSidebar() {
        (view.window?.contentViewController as? MainSplitViewController)?.toggleSidebar()
    }

    func refreshTabBarMetadata() {
        let snap = SessionCoordinator.shared.snapshot
        tabBar.refreshMetadata(tabs: snap.activeWorkspace?.tabs ?? [], activeTabID: snap.activeWorkspace?.activeTabID)
        updateTitleStripPath()
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
        coordinator.requestDaemon(.setTabPersistent(tabID: tabID, persistent: !current))
    }

    private func reloadAll(force: Bool) {
        reloadTabBar()
        reloadIfNeeded(force: force)
    }

    func reloadIfNeeded(force: Bool) {
        guard terminalHost.bounds.width > 1, terminalHost.bounds.height > 1 else {
            pendingReload = (pendingReload ?? false) || force
            return
        }

        let coordinator = SessionCoordinator.shared
        guard let workspace = coordinator.snapshot.activeWorkspace,
              let tab = workspace.activeTab
        else { return }

        let displayNode = zoomedNode(for: tab) ?? tab.rootPane
        let density = coordinator.settings.paneDensity.rawValue
        let key = "\(coordinator.structureRevision)|\(density)|\(workspace.id)|\(tab.id)|\(tab.zoomedPaneID?.uuidString ?? "all")|\(paneKey(displayNode))"
        guard force || key != lastStructureKey else {
            // No per-pane chrome work needed on the fast path (structure unchanged).
            return
        }
        lastStructureKey = key

        paneContainer?.removeFromSuperview()
        let container = PaneContainerView(
            node: displayNode,
            cwd: tab.cwd,
            program: tab.currentCommand,
            agent: tab.agent?.kind.commandToken,
            themeName: coordinator.snapshot.themeName
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
        // Re-assert the focused-pane border after the (re)mount — reused hosts keep
        // their flag, but a freshly shown tab needs its active pane established.
        coordinator.ensureActivePane(for: tab)
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

    init(node: PaneNode, cwd: String, program: String?, agent: String? = nil, themeName: String) {
        self.tabID = SessionCoordinator.shared.snapshot.activeWorkspace?.activeTab?.id
        super.init(frame: .zero)
        HarnessDesign.makeClear(self)
        build(node: node, cwd: cwd, program: program, agent: agent, into: self, separated: false)
    }

    func applyChrome() {
        HarnessDesign.makeClear(self)
        for island in islands {
            island.applyChrome()
        }
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
            let island = PaneIslandView(
                directory: cwd,
                program: program,
                agent: agent,
                separated: separated,
                surfaceID: leaf.surfaceID
            )
            island.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(island)
            let insets = ChromeLayout.cardInsets(separated: separated)
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
            split.tabID = tabID
            split.firstPaneID = firstLeafID(firstNode)
            split.secondPaneID = firstLeafID(secondNode)
            split.delegate = split
            let first = NSView()
            let second = NSView()
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
            let separated = SessionCoordinator.shared.settings.paneDensity.separatedIslands
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

    /// Representative leaf of a subtree (its first leaf in traversal order). Paired
    /// across both children, it uniquely identifies a branch for ratio persistence.
    private func firstLeafID(_ node: PaneNode) -> PaneID? {
        switch node {
        case let .leaf(leaf): return leaf.id
        case let .branch(_, _, first, _): return firstLeafID(first)
        }
    }
}

/// Rounded terminal island. The path and the split controls both live on the tab row.
@MainActor
final class PaneIslandView: NSView {
    private weak var terminalHost: TerminalHostView?
    private let separated: Bool

    init(directory: String, program: String?, agent: String? = nil, separated: Bool, surfaceID: SurfaceID? = nil) {
        self.separated = separated
        super.init(frame: .zero)
        wantsLayer = true
        let chrome = ChromeLayout.island(separated: separated, splitRadius: Double(HarnessDesign.Radius.overlay))
        layer?.cornerRadius = CGFloat(chrome.cornerRadius)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = chrome.cornerRadius > 0
        layer?.borderWidth = 0
        _ = (directory, program, agent, surfaceID)
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func embed(_ host: NSView) {
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
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

    func applyChrome() {
        let c = HarnessChrome.current
        let settings = SessionCoordinator.shared.settings
        let appearance = HarnessChrome.systemAppearance(from: effectiveAppearance)
        let backdropAlpha = CGFloat(ChromeMaterial.backdropFillAlpha(
            stored: settings.backgroundOpacity,
            appearanceMode: settings.appearanceMode,
            systemAppearance: appearance
        ))
        let hairline = (c.border.usingColorSpace(.sRGB) ?? c.border)
        layer?.borderColor = hairline.cgColor
        layer?.backgroundColor = c.terminalBackground.withAlphaComponent(backdropAlpha).cgColor
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
    private var ratioDebounce: DispatchWorkItem?

    override var dividerColor: NSColor { .clear }

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
        persistRatio()
    }

    private func persistRatio() {
        guard let tabID, let firstPaneID, let secondPaneID, subviews.count >= 2 else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 1 else { return }
        let firstSize = isVertical ? subviews[0].frame.width : subviews[0].frame.height
        let ratio = Double(firstSize / total)
        // Coalesce the stream of drag events into one write after the drag settles.
        ratioDebounce?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
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
