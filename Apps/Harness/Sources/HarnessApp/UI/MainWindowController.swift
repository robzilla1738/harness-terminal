import AppKit
import HarnessCore

@MainActor
final class MainWindowController: NSWindowController {
    convenience init() {
        HarnessChrome.update(
            themeName: SessionCoordinator.shared.snapshot.themeName,
            opacity: CGFloat(SessionCoordinator.shared.settings.backgroundOpacity),
            blur: SessionCoordinator.shared.settings.backgroundBlur,
            backgroundHex: SessionCoordinator.shared.settings.customBackgroundHex,
            foregroundHex: SessionCoordinator.shared.settings.customForegroundHex,
            cursorHex: SessionCoordinator.shared.settings.customCursorHex
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
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
        window.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        window.contentViewController = MainSplitViewController()
        // Assigning `contentViewController` resizes the window to the split view's
        // fitting size (~sidebar width). Re-assert the intended default explicitly —
        // otherwise the window opens tiny (previously `minSize` masked this; lowering
        // the floor exposed it).
        window.setContentSize(NSSize(width: 1280, height: 820))
        self.init(window: window)
        window.center()
        applyTransparency()
    }

    func applyChrome() {
        window?.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        applyTransparency()
        (contentViewController as? MainSplitViewController)?.applyChrome()
    }

    /// Re-reads opacity from settings and applies window chrome (not terminal blur).
    func applyTransparency() {
        guard let window else { return }
        let settings = SessionCoordinator.shared.settings
        let opacity = max(0, min(1, settings.backgroundOpacity))
        let isOpaque = opacity >= 0.999

        window.titlebarAppearsTransparent = settings.transparentTitlebar
        window.isOpaque = isOpaque
        window.backgroundColor = isOpaque ? HarnessChrome.current.terminalBackground : .clear

        // Drop the window shadow while translucent. macOS computes the drop shadow from the
        // window's content alpha (a rectangle), so on a translucent window it renders as a
        // dark band hugging the rounded frame. With blur high the blurred backdrop hides it;
        // as blur drops it sharpens into the "hard dark edge at the corners that won't go
        // away." A translucent canvas already reads as glass (and the one window-wide blur
        // gives separation), so no shadow is the clean look; opaque windows keep theirs.
        // `invalidateShadow` forces an immediate recompute (toggling blur via the private CGS
        // API doesn't notify AppKit, which is why a stale shadow lingered).
        window.hasShadow = isOpaque
        window.invalidateShadow()

        // Do NOT force the window's `contentView` to be a layer-backed, clear rectangle.
        // Forcing `wantsLayer` on the contentView makes the whole window layer-backed, and a
        // layer-backed window clips the private CGS background blur to the contentView's
        // RECTANGULAR bounds instead of the system's rounded titled-window frame — squaring the
        // corners and leaving a dark compositing seam (hairline) around the rounded edge that
        // hardens as the blur thins. Left non-layer-backed (a plain `NSView` is transparent by
        // default, so the blur still shows through), the window server rounds the blur together
        // with the frame — exactly how Ghostty keeps the same CGS blur rounded. Chrome/terminal
        // subviews keep their own layer backing as needed; the root contentView must not.
        // INVARIANT: NO site may layer-back the root. `MainSplitViewController.loadView` creates
        // it as a plain `NSView`, and `MainSplitViewController.applyChrome` must NOT `makeClear`
        // the root (`makeClear` sets `wantsLayer`) — that re-layer-backs it on every chrome
        // refresh and the dark seam returns. So simply not touching it here keeps it correct.

        // One uniform blur for the whole window — the same private CGS surface blur
        // modern terminals use on macOS. This is the single blur source: the terminal keeps
        // only `background-opacity` (color translucency, no the renderer blur), and the
        // chrome hides its vibrancy material when translucent, so terminal and chrome
        // share exactly one blurred backdrop. (the renderer's own `background-blur` is a
        // no-op in embedded mode since it doesn't own this NSWindow.) Opaque → no blur.
        WindowBlur.apply(radius: isOpaque ? 0 : settings.backgroundBlur, to: window)
    }
}
