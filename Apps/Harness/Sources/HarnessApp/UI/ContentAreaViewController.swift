import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
final class ContentAreaViewController: NSViewController, TerminalTabBarDelegate {
    private let tabBar = TerminalTabBarView()
    private let terminalHost = NSView()
    private var paneContainer: PaneContainerView?
    private var lastStructureKey = ""

    override func loadView() {
        view = NSView()
        HarnessDesign.applyTerminalChrome(to: view)
    }

    func applyChrome() {
        HarnessDesign.applyTerminalChrome(to: view)
        HarnessDesign.makeClear(terminalHost)
        tabBar.applyChrome()
        paneContainer?.applyChrome()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabBar.delegate = self
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        terminalHost.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(terminalHost)

        let tabBarLine = HarnessDesign.divider()
        tabBarLine.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(tabBar)
        view.addSubview(tabBarLine)
        view.addSubview(terminalHost)

        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBarLine.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabBarLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBarLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            terminalHost.topAnchor.constraint(equalTo: tabBarLine.bottomAnchor),
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
        reloadAll(force: true)
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
    }

    func refreshTabBarMetadata() {
        let snap = SessionCoordinator.shared.snapshot
        tabBar.refreshMetadata(tabs: snap.activeWorkspace?.tabs ?? [], activeTabID: snap.activeWorkspace?.activeTabID)
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
        coordinator.closeActiveTab()
    }

    private func reloadAll(force: Bool) {
        reloadTabBar()
        reloadIfNeeded(force: force)
    }

    func reloadIfNeeded(force: Bool) {
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
    }

    private func paneKey(_ node: PaneNode) -> String {
        switch node {
        case let .leaf(leaf):
            return "l:\(leaf.surfaceID.uuidString)"
        case let .branch(direction, ratio, first, second):
            return "b:\(direction.rawValue):\(ratio):\(paneKey(first)):\(paneKey(second))"
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

    init(node: PaneNode, cwd: String, themeName: String) {
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
            for tab in workspace.tabs where tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                return tab
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
            let split = NSSplitView()
            split.dividerStyle = .thin
            split.isVertical = direction == .horizontal
            split.delegate = SplitRatioDelegate.shared
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
            DispatchQueue.main.async {
                let position = (direction == .horizontal ? split.frame.width : split.frame.height) * ratio
                if position > 50 {
                    split.setPosition(position, ofDividerAt: 0)
                }
            }
            build(node: firstNode, cwd: cwd, into: first)
            build(node: secondNode, cwd: cwd, into: second)
        }
    }
}

@MainActor
final class SplitRatioDelegate: NSObject, NSSplitViewDelegate {
    static let shared = SplitRatioDelegate()
}
