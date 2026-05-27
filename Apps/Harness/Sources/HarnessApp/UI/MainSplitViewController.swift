import AppKit
import HarnessCore

@MainActor
final class MainSplitViewController: NSViewController {
    private let split = NSSplitView()
    private let sidebar = HarnessSidebarPanelViewController()
    private let content = ContentAreaViewController()

    override func loadView() {
        let root = NSView()
        HarnessDesign.makeClear(root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "HarnessMainSplit"
        split.delegate = SplitChromeDelegate.shared

        let sidebarContainer = NSView()
        HarnessDesign.applySidebarChrome(to: sidebarContainer)
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(sidebar.view)
        NSLayoutConstraint.activate([
            sidebar.view.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebar.view.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebar.view.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])

        // Sidebar/terminal separation comes from the background color contrast —
        // no hard edge line, mirroring Ghostty/cmux.

        split.addSubview(sidebarContainer)
        split.addSubview(content.view)
        addChild(sidebar)
        addChild(content)

        split.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: view.topAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        DispatchQueue.main.async { [weak self] in
            self?.setSidebarVisible(SessionCoordinator.shared.settings.sidebarVisible)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(snapshotChanged),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
    }

    func applyChrome() {
        HarnessDesign.makeClear(view)
        if let sidebarContainer = split.subviews.first {
            HarnessDesign.applySidebarChrome(to: sidebarContainer)
        }
        sidebar.applyChromeColors()
        content.applyChrome()
        (view.window?.windowController as? MainWindowController)?.applyTransparency()
    }

    @objc private func snapshotChanged(_ note: Notification) {
        let metadataOnly = note.userInfo?["metadataOnly"] as? Bool ?? false
        if note.userInfo?["chromeChanged"] as? Bool == true {
            applyChrome()
            (view.window?.windowController as? MainWindowController)?.applyChrome()
        }
        if metadataOnly {
            sidebar.refreshMetadata()
            content.refreshTabBarMetadata()
        } else {
            sidebar.reload()
            content.reloadTabBar()
        }
        updateWindowTitle()
    }

    private func updateWindowTitle() {
        let snap = SessionCoordinator.shared.snapshot
        view.window?.title = snap.activeWorkspace.map { "Harness — \($0.name)" } ?? "Harness"
    }

    func setSidebarVisible(_ visible: Bool) {
        split.subviews.first?.isHidden = !visible
        SessionCoordinator.shared.settings.sidebarVisible = visible
        try? SessionCoordinator.shared.settings.save()
        if visible {
            split.setPosition(HarnessDesign.sidebarWidth, ofDividerAt: 0)
        } else {
            split.setPosition(0, ofDividerAt: 0)
        }
    }
}

@MainActor
private final class SplitChromeDelegate: NSObject, NSSplitViewDelegate {
    static let shared = SplitChromeDelegate()

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimum: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? 200 : proposedMinimum
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximum: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        index == 0 ? 320 : proposedMaximum
    }

    func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        var rect = proposedEffectiveRect
        rect.size.width = 4
        return rect
    }
}
