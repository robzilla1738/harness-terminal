import AppKit
import HarnessCore
import QuartzCore

@MainActor
final class MainSplitViewController: NSViewController {
    private let split = NSSplitView()
    private let sidebar = HarnessSidebarPanelViewController()
    private let content = ContentAreaViewController()
    private let statusLine = StatusLineView()
    /// 1px hairline along the inner edge of the sidebar — adds quiet definition
    /// between sidebar/terminal without resorting to a draggable divider line.
    private let edgeDivider = NSView()
    /// Bumped each time a sidebar collapse/expand starts so any in-flight animation
    /// frame bails out — prevents two toggles from fighting over the divider position.
    private var sidebarAnimToken = 0

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

        split.addSubview(sidebarContainer)
        split.addSubview(content.view)
        addChild(sidebar)
        addChild(content)

        split.translatesAutoresizingMaskIntoConstraints = false
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        edgeDivider.wantsLayer = true
        edgeDivider.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(split)
        view.addSubview(statusLine)
        view.addSubview(edgeDivider)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: view.topAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusLine.topAnchor),

            statusLine.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLine.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            edgeDivider.topAnchor.constraint(equalTo: view.topAnchor),
            edgeDivider.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            edgeDivider.leadingAnchor.constraint(equalTo: sidebarContainer.trailingAnchor),
            edgeDivider.widthAnchor.constraint(equalToConstant: 1),
        ])

        edgeDivider.layer?.backgroundColor = resolvedDividerColor().cgColor

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

    /// Resolve the divider line color: user override (`settings.dividerHex`) wins;
    /// otherwise the theme's border × alpha.
    private func resolvedDividerColor() -> NSColor {
        let custom = SessionCoordinator.shared.settings.dividerHex
        if let hex = custom, let color = NSColor.fromHex(hex) { return color }
        let c = HarnessChrome.current
        return c.border.withAlphaComponent(c.isDark ? 0.45 : 0.65)
    }

    func applyChrome() {
        HarnessDesign.makeClear(view)
        if let sidebarContainer = split.subviews.first {
            // Keep this transparent — the sidebar view inside owns the chrome.
            HarnessDesign.makeClear(sidebarContainer)
        }
        edgeDivider.layer?.backgroundColor = resolvedDividerColor().cgColor
        // Tell the window controller to repaint the window bg with the (possibly
        // new) chrome color × opacity.
        (view.window?.windowController as? MainWindowController)?.applyTransparency()
        sidebar.applyChromeColors()
        content.applyChrome()
        statusLine.applyChrome()
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
        setSidebarVisible(visible, animated: false)
    }

    /// Collapse/expand the sidebar. `NSSplitView.setPosition` is not animatable via the
    /// animator proxy, so for a genuinely fluid slide we drive the divider ourselves
    /// with an eased per-frame stepper. A token cancels any in-flight animation.
    func setSidebarVisible(_ visible: Bool, animated: Bool) {
        SessionCoordinator.shared.settings.sidebarVisible = visible
        try? SessionCoordinator.shared.settings.save()
        sidebarAnimToken &+= 1
        let target = visible ? HarnessDesign.sidebarWidth : 0

        guard animated, let panel = split.subviews.first else {
            split.subviews.first?.isHidden = !visible
            split.setPosition(target, ofDividerAt: 0)
            return
        }

        // Expanding: unhide before the slide so the panel is visible as it grows.
        panel.isHidden = false
        let start = panel.frame.width
        guard abs(target - start) > 0.5 else {
            split.setPosition(target, ofDividerAt: 0)
            if !visible { panel.isHidden = true }
            return
        }
        animateSidebar(from: start, to: target, t0: CACurrentMediaTime(), visible: visible, token: sidebarAnimToken)
    }

    private func animateSidebar(from start: CGFloat, to target: CGFloat, t0: CFTimeInterval, visible: Bool, token: Int) {
        guard token == sidebarAnimToken, let panel = split.subviews.first else { return }
        let duration = HarnessDesign.Motion.standard
        let raw = min(1, max(0, (CACurrentMediaTime() - t0) / duration))
        // easeInOutQuad — smooth start and settle.
        let eased = raw < 0.5 ? 2 * raw * raw : 1 - pow(-2 * raw + 2, 2) / 2
        // Drive the divider inside a transaction with implicit actions OFF and lay
        // out synchronously each frame. Without this, the manual per-frame
        // setPosition lets the sidebar's vibrancy/glass backdrop animate its bounds
        // a frame behind the divider — it re-samples at the stale width and smears
        // into the banding seen mid-collapse. Disabling actions + an immediate
        // layout keeps the backdrop locked to the divider every step.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        split.setPosition(start + (target - start) * CGFloat(eased), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        CATransaction.commit()
        if raw >= 1 {
            if !visible { panel.isHidden = true }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            MainActor.assumeIsolated {
                self?.animateSidebar(from: start, to: target, t0: t0, visible: visible, token: token)
            }
        }
    }

    func toggleSidebar() {
        setSidebarVisible(!SessionCoordinator.shared.settings.sidebarVisible, animated: true)
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
