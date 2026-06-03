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
    /// Owned (not a singleton) so collapse state is per-window. Carries the
    /// `allowFullCollapse` flag the divider min-coordinate reads.
    private let splitDelegate = SplitChromeDelegate()

    override func loadView() {
        // The root contentView must stay a plain, NON-layer-backed NSView. A plain NSView
        // draws nothing (transparent by default), so the window blur shows through — but it
        // is *not* layer-backed, so the window server rounds the frame + CGS background blur
        // together. Calling `makeClear` here would set `wantsLayer` and
        // layer-back the whole window, which clips the blur to a rectangle and leaves a dark
        // compositing seam at the rounded edge. See MainWindowController.applyTransparency.
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        split.isVertical = true
        split.dividerStyle = .thin
        // No autosaveName: visibility lives in `settings.sidebarVisible` and is
        // re-applied on load; an autosaved divider width would restore a stale
        // collapsed state and fight the settings-driven restore.
        split.delegate = splitDelegate

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

    /// Resolve the divider line color: user override (`settings.dividerHex`) wins; otherwise
    /// a quiet near-background hairline — `#1E1E1E` on dark themes (the default look), and the
    /// theme's border on light themes (where a near-black line would read as a hard rule).
    private func resolvedDividerColor() -> NSColor {
        if let hex = SessionCoordinator.shared.settings.dividerHex, let color = NSColor.fromHex(hex) {
            return color
        }
        let c = HarnessChrome.current
        return c.isDark
            ? (NSColor.fromHex(HarnessChromePalette.defaultDarkDividerHex) ?? c.border)
            : c.border.withAlphaComponent(0.65)
    }

    func applyChrome() {
        // Never `makeClear(view)` here: the root contentView must stay non-layer-backed
        // (see loadView) so the window stays rounded with no dark perimeter seam. It is
        // transparent already; there is nothing to repaint on it.
        if let sidebarContainer = split.subviews.first {
            // Keep this transparent — the sidebar view inside owns the chrome. This is a
            // child layer-backing island and does not affect the root's backing.
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
    ///
    /// `allowFullCollapse` is set on the delegate for the whole move so the divider's
    /// min-coordinate drops to 0 (it's 200 at rest, so a *user drag* can't shrink the
    /// sidebar to an unusable sliver — but a programmatic collapse must reach 0).
    func setSidebarVisible(_ visible: Bool, animated: Bool) {
        SessionCoordinator.shared.settings.sidebarVisible = visible
        try? SessionCoordinator.shared.settings.save()
        sidebarAnimToken &+= 1
        let target = visible ? HarnessDesign.sidebarWidth : 0
        splitDelegate.allowFullCollapse = true

        guard animated, let panel = split.subviews.first else {
            let panel = split.subviews.first
            panel?.isHidden = false              // unhide so setPosition can size it to 0
            split.setPosition(target, ofDividerAt: 0)
            panel?.isHidden = !visible
            splitDelegate.allowFullCollapse = false
            edgeDivider.isHidden = !visible
            updateContentLeadingInset(visible: visible)
            return
        }

        // Unhide before the slide so the panel is visible as it shrinks/grows.
        panel.isHidden = false
        // Show/hide the inner hairline immediately so it never strands over the terminal.
        edgeDivider.isHidden = !visible
        let start = panel.frame.width
        guard abs(target - start) > 0.5 else {
            split.setPosition(target, ofDividerAt: 0)
            if !visible { panel.isHidden = true }
            splitDelegate.allowFullCollapse = false
            updateContentLeadingInset(visible: visible)
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
        let width = start + (target - start) * CGFloat(eased)
        // Drive the divider inside a transaction with implicit actions OFF and lay
        // out synchronously each frame. Without this, the manual per-frame
        // setPosition lets the sidebar's vibrancy/glass backdrop animate its bounds
        // a frame behind the divider — it re-samples at the stale width and smears
        // into the banding seen mid-collapse. Disabling actions + an immediate
        // layout keeps the backdrop locked to the divider every step.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        split.setPosition(width, ofDividerAt: 0)
        // Interpolate the tab-strip inset against the live sidebar width so it slides
        // in lockstep with the divider rather than snapping at the end.
        setContentLeadingInset(forSidebarWidth: width)
        split.layoutSubtreeIfNeeded()
        CATransaction.commit()
        if raw >= 1 {
            if !visible { panel.isHidden = true }
            splitDelegate.allowFullCollapse = false   // restore the 200pt drag floor
            updateContentLeadingInset(visible: visible)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            MainActor.assumeIsolated {
                self?.animateSidebar(from: start, to: target, t0: t0, visible: visible, token: token)
            }
        }
    }

    /// Leading inset the title strip's path readout needs to clear the macOS traffic lights
    /// when the sidebar is fully collapsed (content shifts to x=0 under `.fullSizeContentView`).
    /// The tab bar itself sits below the lights and never needs one.
    private let trafficLightInset: CGFloat = 72

    /// Inset the strip readout proportionally to how collapsed the sidebar is: full inset
    /// at width 0, none once the sidebar is wide enough to cover the traffic lights.
    private func setContentLeadingInset(forSidebarWidth width: CGFloat) {
        let t = max(0, min(1, 1 - width / trafficLightInset))
        content.setTabBarLeadingInset(trafficLightInset * t)
    }

    private func updateContentLeadingInset(visible: Bool) {
        content.setTabBarLeadingInset(visible ? 0 : trafficLightInset)
    }

    func toggleSidebar() {
        setSidebarVisible(!SessionCoordinator.shared.settings.sidebarVisible, animated: true)
    }

}

@MainActor
private final class SplitChromeDelegate: NSObject, NSSplitViewDelegate {
    /// While a programmatic collapse/expand is running, let the divider reach 0 so the
    /// sidebar can fully disappear. At rest it's false, so a *user drag* still floors
    /// at 200pt and can't shrink the sidebar to an unusable sliver.
    var allowFullCollapse = false

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimum: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        guard index == 0 else { return proposedMinimum }
        return allowFullCollapse ? 0 : 200
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
