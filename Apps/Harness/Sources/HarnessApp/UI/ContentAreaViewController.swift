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
        HarnessDesign.makeClear(view)
        refreshTerminalHostFill()
        titleStrip.applyColors()
        tabBar.applyChrome()
        paneContainer?.applyChrome()
    }

    /// Reflect the active tab's cwd in the title strip's folder/path readout. Hidden while a
    /// CLI agent (claude, codex, cursor-agent, …) owns the pane: the agent's own UI is the
    /// context then, and a shell-cwd readout over it is just noise. Returns when the tool exits.
    private func updateTitleStripPath() {
        let snap = SessionCoordinator.shared.snapshot
        guard let tab = snap.activeWorkspace?.activeTab else {
            titleStrip.setPath("")
            return
        }
        let agentActive = tab.agent != nil || AgentTitleInference.kind(from: tab.title) != nil
        titleStrip.setPath(agentActive ? "" : tab.cwd)
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
        let opacity = HarnessSettings.clampedOpacity(SessionCoordinator.shared.settings.backgroundOpacity)
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

        view.addSubview(titleStrip)
        view.addSubview(tabBar)
        view.addSubview(terminalHost)

        NSLayoutConstraint.activate([
            // Draggable title strip above the tabs: window-move grab area + Ghostty-style
            // folder/path readout. Pushes the tab pills below the traffic-light band.
            titleStrip.topAnchor.constraint(equalTo: view.topAnchor),
            titleStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleStrip.heightAnchor.constraint(equalToConstant: WindowTitleStripView.height),

            tabBar.topAnchor.constraint(equalTo: titleStrip.bottomAnchor),
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
        titleStrip.setLeadingInset(inset)
        tabBar.setLeadingInset(0)
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
        let key = "\(coordinator.structureRevision)|\(workspace.id)|\(tab.id)|\(tab.zoomedPaneID?.uuidString ?? "all")|\(paneKey(displayNode))"
        guard force || key != lastStructureKey else {
            paneContainer?.refreshChrome(snapshot: coordinator.snapshot)
            return
        }
        lastStructureKey = key

        paneContainer?.removeFromSuperview()
        let container = PaneContainerView(
            node: displayNode,
            cwd: tab.cwd,
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

    init(node: PaneNode, cwd: String, themeName: String) {
        self.tabID = SessionCoordinator.shared.snapshot.activeWorkspace?.activeTab?.id
        super.init(frame: .zero)
        HarnessDesign.makeClear(self)
        build(node: node, cwd: cwd, into: self)
    }

    func applyChrome() {
        HarnessDesign.makeClear(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refreshChrome(snapshot: SessionSnapshot) {
        guard let tab = snapshot.activeWorkspace?.activeTab else { return }
        for surfaceID in tab.rootPane.allSurfaceIDs() {
            if let match = tabFor(surfaceID: surfaceID, in: snapshot),
               let host = TerminalPaneRegistryAccess.host(for: surfaceID)
            {
                host.showsWaitingRing = match.status == .waiting
            }
        }
    }

    private func tabFor(surfaceID: SurfaceID, in snapshot: SessionSnapshot) -> Tab? {
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                    return tab
                }
            }
        }
        return nil
    }

    private func build(node: PaneNode, cwd: String, into parent: NSView) {
        switch node {
        case let .leaf(leaf):
            let host = coordinator.terminalHost(for: leaf.surfaceID, cwd: cwd)
            host.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(host)
            NSLayoutConstraint.activate([
                host.topAnchor.constraint(equalTo: parent.topAnchor),
                host.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                host.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            ])
            if let tab = coordinator.snapshot.activeWorkspace?.activeTab {
                host.showsWaitingRing = tab.status == .waiting
            }
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
            build(node: firstNode, cwd: cwd, into: first)
            build(node: secondNode, cwd: cwd, into: second)
            DispatchQueue.main.async {
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

/// NSSplitView for terminal panes: tints its divider to the theme, widens the grab
/// (and cursor) area beyond the 1px thin divider, and persists user divider drags to
/// the daemon so split ratios survive relaunch. Acts as its own delegate.
@MainActor
final class HarnessSplitView: NSSplitView, NSSplitViewDelegate {
    var tabID: TabID?
    var firstPaneID: PaneID?
    var secondPaneID: PaneID?
    private var ratioDebounce: DispatchWorkItem?

    override var dividerColor: NSColor { HarnessChrome.current.border }

    func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        // Widen the interactive/cursor zone past the 1px thin divider. NSSplitView
        // shows the resize cursor over the effective rect, so this covers the cursor.
        var rect = proposedEffectiveRect
        if isVertical { rect.size.width = 8 } else { rect.size.height = 8 }
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
