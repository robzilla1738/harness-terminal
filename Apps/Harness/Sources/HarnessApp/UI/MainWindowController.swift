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
        window.minSize = NSSize(width: 960, height: 600)
        window.titlebarAppearsTransparent = SessionCoordinator.shared.settings.transparentTitlebar
        window.titleVisibility = .hidden
        if #available(macOS 11.0, *) {
            window.titlebarSeparatorStyle = .none
        }
        window.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        window.contentViewController = MainSplitViewController()
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

        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
            if isOpaque {
                // Opaque: the system window mask crops the solid fill cleanly, and
                // leaving clipping off keeps the Metal terminal layer un-masked.
                content.layer?.cornerRadius = 0
                content.layer?.masksToBounds = false
            } else {
                // Translucent: clip the whole composited stack (chrome + terminal + the
                // CGS blur showing through) to the system corner radius. The rectangular
                // CGS backdrop blur is otherwise masked only by the square contentView,
                // so it pokes a light fringe past the window's rounded corners. Clipping
                // makes the corners transparent, so the server blur isn't shown there.
                content.layer?.cornerRadius = Self.systemWindowCornerRadius(for: window)
                content.layer?.cornerCurve = .continuous
                content.layer?.masksToBounds = true
            }
        }

        // One uniform blur for the whole window — the same private CGS surface blur
        // modern terminals use on macOS. This is the single blur source: the terminal keeps
        // only `background-opacity` (color translucency, no the renderer blur), and the
        // chrome hides its vibrancy material when translucent, so terminal and chrome
        // share exactly one blurred backdrop. (the renderer's own `background-blur` is a
        // no-op in embedded mode since it doesn't own this NSWindow.) Opaque → no blur.
        WindowBlur.apply(radius: isOpaque ? 0 : settings.backgroundBlur, to: window)
    }

    /// Best-effort system window corner radius. There's no public API, and macOS 26
    /// (Liquid Glass) rounds windows more than classic macOS — so read the theme frame
    /// view's backing-layer radius when it's realized, falling back to a per-OS constant
    /// (bias slightly large: over-rounding hides under the system mask, under-rounding
    /// reintroduces the fringe).
    static func systemWindowCornerRadius(for window: NSWindow) -> CGFloat {
        if let frameLayer = window.contentView?.superview?.layer,
           frameLayer.cornerRadius > 0.5 {
            return frameLayer.cornerRadius
        }
        if #available(macOS 26.0, *) { return 16 }
        return 10
    }
}
