import AppKit
import HarnessCore

@MainActor
final class MainSplitViewController: NSViewController {
    private let split = NSSplitView()
    private let sidebar = HarnessSidebarPanelViewController()
    private let content = ContentAreaViewController()
    /// 1px hairline along the inner edge of the sidebar — adds quiet definition
    /// between sidebar/terminal without resorting to a draggable divider line.
    private let edgeDivider = NSView()

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

        // Container is a transparent wrapper so the sidebar.view's own chrome
        // backdrop is the only one in play. Stacking two ChromeBackdrops (one
        // here, one in HarnessSidebarPanelViewController.loadView) doubled up
        // the glass+tint and shifted the sidebar's perceived tint relative to
        // the terminal side — making the top of the window read as a darker
        // strip even though both regions request the same theme color.
        let sidebarContainer = NSView()
        HarnessDesign.makeClear(sidebarContainer)
        sidebarContainer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(sidebar.view)
        NSLayoutConstraint.activate([
            sidebar.view.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            sidebar.view.leadingAnchor.constraint(equalTo: sidebarContainer.leadingAnchor),
            sidebar.view.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
        ])

        // Thin inner-edge hairline on the trailing edge of the sidebar — picked up
        // from the theme palette so it stays whisper-quiet on light themes.
        edgeDivider.wantsLayer = true
        edgeDivider.translatesAutoresizingMaskIntoConstraints = false
        sidebarContainer.addSubview(edgeDivider)
        NSLayoutConstraint.activate([
            edgeDivider.topAnchor.constraint(equalTo: sidebarContainer.topAnchor),
            edgeDivider.bottomAnchor.constraint(equalTo: sidebarContainer.bottomAnchor),
            edgeDivider.trailingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            edgeDivider.widthAnchor.constraint(equalToConstant: 1),
        ])

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

        edgeDivider.layer?.backgroundColor = HarnessChrome.current.border.withAlphaComponent(
            HarnessChrome.current.isDark ? 0.45 : 0.65
        ).cgColor

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
            // Keep this transparent — the sidebar view inside owns the chrome.
            HarnessDesign.makeClear(sidebarContainer)
        }
        edgeDivider.layer?.backgroundColor = HarnessChrome.current.border.withAlphaComponent(
            HarnessChrome.current.isDark ? 0.45 : 0.65
        ).cgColor
        sidebar.applyChromeColors()
        content.applyChrome()
        (view.window?.windowController as? MainWindowController)?.applyTransparency()
    }

    @objc private func snapshotChanged(_ note: Notification) {
        let metadataOnly = note.userInfo?["metadataOnly"] as? Bool ?? false
        if note.userInfo?["chromeChanged"] as? Bool == true {
            // Cross-dissolve the chrome (theme switch) instead of a hard color pop.
            // Re-arming the flag per cascade means rapid successive switches just
            // restart the fade rather than queueing.
            ChromeBackdrop.crossfadeNextUpdate = true
            applyChrome()
            (view.window?.windowController as? MainWindowController)?.applyChrome()
            ChromeBackdrop.crossfadeNextUpdate = false
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
