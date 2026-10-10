import AppKit
import HarnessCore

@MainActor
final class MainWindowController: NSWindowController {
    /// Autosave key for the main window frame. Shared with Settings so the launch-time
    /// restore and the live "Remember window size" toggle use the exact same name.
    static let frameAutosaveName = "HarnessMainWindow"

    /// Faint hairline around the whole window edge. Color/opacity from
    /// settings (`windowBorderHex`/`windowBorderOpacity`); re-applied in `applyTransparency`.
    private let borderOverlay = WindowBorderOverlayView()

    /// The session this window shows.
    var context: WindowContext? { (contentViewController as? MainSplitViewController)?.context }

    /// `sessionID`: the session this window shows (on `owner`'s daemon); nil follows the
    /// active one.
    convenience init(sessionID: SessionID? = nil, owner: String = DaemonSidebar.localID) {
        HarnessChrome.update(
            themeName: SessionCoordinator.shared.snapshot.themeName,
            opacity: CGFloat(SessionCoordinator.shared.settings.backgroundOpacity),
            blur: SessionCoordinator.shared.settings.backgroundBlur,
            appearanceMode: SessionCoordinator.shared.settings.appearanceMode,
            systemLightThemeName: SessionCoordinator.shared.settings.systemLightThemeName,
            systemDarkThemeName: SessionCoordinator.shared.settings.systemDarkThemeName,
            backgroundHex: SessionCoordinator.shared.settings.customBackgroundHex,
            foregroundHex: SessionCoordinator.shared.settings.customForegroundHex,
            cursorHex: SessionCoordinator.shared.settings.customCursorHex
        )

        let previousWindow = NSApp.orderedWindows.first { $0.contentViewController is MainSplitViewController }
        let window = HarnessMainWindow(
            contentRect: NSRect(origin: .zero, size: HarnessDesign.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Harness"
        window.isRestorable = false
        // Allow a genuinely narrow window (single-pane / sidebar-collapsed use). The
        // sidebar can be hidden (⌘\), so we don't reserve room for it in the floor.
        window.minSize = NSSize(width: 480, height: 400)
        window.titlebarAppearsTransparent = SessionCoordinator.shared.settings.transparentTitlebar
        window.titleVisibility = .hidden
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        // Retain native window controls in a transparent unified titlebar. Their
        // vertical center follows Harness's 46pt tab row (30pt pill + two 8pt gaps).
        let toolbar = NSToolbar(identifier: "HarnessTitleRow")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        Self.alignTrafficLights(in: window)
        HarnessDesign.trafficLightTrailingEdge = Self.trafficLightTrailingEdge(in: window) ?? HarnessDesign.trafficLightTrailingEdge
        Self.applyWindowAppearance(window)
        let context = WindowContext(sessionID: sessionID, owner: owner)
        WindowContexts.register(context)
        window.contentViewController = MainSplitViewController(context: context)
        // Assigning `contentViewController` resizes the window to the split view's
        // fitting size (~sidebar width). Re-assert the intended default explicitly —
        // otherwise the window opens tiny (previously `minSize` masked this; lowering
        // the floor exposed it).
        window.setContentSize(HarnessDesign.defaultWindowSize)
        window.contentView?.layoutSubtreeIfNeeded()
        let settings = SessionCoordinator.shared.settings
        let defaultSize = HarnessDesign.defaultContentSize(
            settings: settings, scale: window.backingScaleFactor,
            statusHeight: (window.contentViewController as? MainSplitViewController)?.statusLineHeight ?? 0
        )
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let maxContent = visibleFrame.map { window.contentRect(forFrameRect: $0).size } ?? defaultSize
        window.setContentSize(NSSize(width: min(defaultSize.width, maxContent.width),
                                     height: min(defaultSize.height, maxContent.height)))
        self.init(window: window)
        // AppKit may relayout titlebar controls while installing the content controller.
        Self.alignTrafficLights(in: window)
        HarnessDesign.trafficLightTrailingEdge = Self.trafficLightTrailingEdge(in: window) ?? HarnessDesign.trafficLightTrailingEdge
        // Window-edge hairline — topmost subview of the root contentView (added after the
        // split view loads, so it stays above all chrome). Click-through; layer island only.
        if let contentView = window.contentView {
            borderOverlay.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(borderOverlay)
            NSLayoutConstraint.activate([
                borderOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
                borderOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                borderOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                borderOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ])
        }
        // Window frame persistence: when enabled, restore the saved frame (size +
        // position) and keep it updated automatically; otherwise open centered at the
        // default size. Window-level only — no effect on sessions or the terminal.
        // Only the first window restores the saved frame; later ones cascade from the key window.
        if WindowContexts.all.count > 1 {
            if settings.restoreWindowSize, let previousWindow {
                window.setContentSize(previousWindow.contentView?.bounds.size ?? defaultSize)
            }
            window.center()
        } else if SessionCoordinator.shared.settings.restoreWindowSize {
            window.setFrameAutosaveName(Self.frameAutosaveName)
            if !window.setFrameUsingName(Self.frameAutosaveName) {
                window.center()
            }
        } else {
            window.center()
        }
        applyTransparency()
    }

    func applyChrome() {
        if let window { Self.applyWindowAppearance(window) }
        applyTransparency()
        (contentViewController as? MainSplitViewController)?.applyChrome()
    }

    /// Frame saved before entering non-native fullscreen; nil when not in it.
    private var preFullscreenFrame: NSRect?

    /// Non-native ("fast") full screen — fill the screen without the macOS Space transition the
    /// native ⌃⌘F uses. Auto-hides the menu bar + Dock and resizes to the screen frame; toggles
    /// back to the saved frame. Deliberately does NOT touch the style mask, so the transparent
    /// titlebar, tabs-in-titlebar, and the single window-wide blur are all preserved.
    @objc func toggleNonNativeFullscreen(_ sender: Any?) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        if let saved = preFullscreenFrame {
            NSApp.presentationOptions = []
            window.setFrame(saved, display: true, animate: false)
            preFullscreenFrame = nil
        } else if let screen = window.screen ?? NSScreen.main {
            preFullscreenFrame = window.frame
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.setFrame(screen.frame, display: true, animate: false)
        }
    }

    func effectiveAppearanceDidChange() {
        // Senders can fire mid-transition (the NSApp KVO lands before the window's own
        // appearance settles); hop one runloop turn so the chrome palette, the theme
        // resolution, and the window all read the same settled value. Idempotent — the
        // KVO, the split view's viewDidChangeEffectiveAppearance, and the distributed
        // theme notification may all schedule this for one flip.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            let didRefresh = SessionCoordinator.shared.refreshChromeForEffectiveAppearanceChange(
                systemAppearance: HarnessChrome.systemAppearance(from: window.effectiveAppearance)
            )
            if didRefresh {
                self.applyChrome()
            }
        }
    }

    private static func applyWindowAppearance(_ window: NSWindow) {
        if SessionCoordinator.shared.settings.appearanceMode == .macOSSystem {
            window.appearance = nil
        } else {
            window.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        }
    }

    /// Re-reads opacity from settings and applies window chrome (not terminal blur).
    func applyTransparency() {
        guard let window else { return }
        let settings = SessionCoordinator.shared.settings

        window.titlebarAppearsTransparent = settings.transparentTitlebar
        // Do NOT force the window's `contentView` to be a layer-backed, clear rectangle.
        // Forcing `wantsLayer` on the contentView makes the whole window layer-backed, and a
        // layer-backed window clips the private CGS background blur to the contentView's
        // RECTANGULAR bounds instead of the system's rounded titled-window frame — squaring the
        // corners and leaving a dark compositing seam (hairline) around the rounded edge that
        // hardens as the blur thins. Left non-layer-backed (a plain `NSView` is transparent by
        // default, so the blur still shows through), the window server rounds the blur together
        // with the frame. Chrome/terminal
        // subviews keep their own layer backing as needed; the root contentView must not.
        // INVARIANT: NO site may layer-back the root. `MainSplitViewController.loadView` creates
        // it as a plain `NSView`, and `MainSplitViewController.applyChrome` must NOT `makeClear`
        // the root (`makeClear` sets `wantsLayer`) — that re-layer-backs it on every chrome
        // refresh and the dark seam returns. So simply not touching it here keeps it correct.

        // Window-edge hairline: custom hex wins; otherwise a theme-derived faint grey
        // (white on dark themes, black on light — the opacity makes it read as grey).
        let borderColor = settings.windowBorderHex.flatMap { NSColor.fromHex($0) }
            ?? (HarnessChrome.current.isDark ? .white : .black)
        borderOverlay.update(color: borderColor, opacity: CGFloat(settings.windowBorderOpacity))

        // One uniform blur for the whole window — the same private CGS surface blur
        // modern terminals use on macOS. This is the single blur source: the terminal keeps
        // only `background-opacity` (color translucency, no the renderer blur), and the
        // chrome hides its vibrancy material when translucent, so terminal and chrome
        // share exactly one blurred backdrop. (the renderer's own `background-blur` is a
        // no-op in embedded mode since it doesn't own this NSWindow.) Opaque → no blur.
        WindowAppearance.applyTransparency(
            opacity: settings.backgroundOpacity,
            blur: settings.backgroundBlur,
            opaqueBackground: HarnessChrome.current.terminalBackground,
            to: window
        )
    }

    static func alignTrafficLights(in window: NSWindow) {
        // Full-screen titlebar controls belong to the system's revealable toolbar.
        guard !window.styleMask.contains(.fullScreen) else { return }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
            let rect = container.convert(button.frame, to: nil)
            let desiredCenter = window.frame.height - HarnessDesign.titleRowCenter
            let delta = desiredCenter - rect.midY
            guard abs(delta) > 0.01 else { continue }
            let target = container.convert(NSPoint(x: rect.midX, y: desiredCenter), from: nil)
            button.setFrameOrigin(NSPoint(x: button.frame.minX,
                                          y: button.frame.minY + target.y - button.frame.midY))
        }
    }

    static func trafficLightTrailingEdge(in window: NSWindow) -> CGFloat? {
        guard let button = window.standardWindowButton(.zoomButton), let frameView = button.superview else { return nil }
        let edge = frameView.convert(button.frame, to: nil).maxX
        return edge > 0 && edge < 160 ? edge : nil
    }

    /// Distance from the window's top edge to the close button's center.
    static func trafficLightCenter(in window: NSWindow) -> CGFloat? {
        guard let button = window.standardWindowButton(.closeButton), let frameView = button.superview else { return nil }
        let inWindow = frameView.convert(button.frame, to: nil)
        let center = window.frame.height - inWindow.midY
        return center > 0 && center < 80 ? center.rounded() : nil
    }
}

/// AppKit can reposition native titlebar buttons during window and toolbar updates.
/// Reapply the shared center after that layout, without moving the window or its panes.
private final class HarnessMainWindow: NSWindow {
    override func update() {
        super.update()
        MainWindowController.alignTrafficLights(in: self)
    }
}
