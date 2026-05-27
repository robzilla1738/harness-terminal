import AppKit
import HarnessCore

@MainActor
final class MainWindowController: NSWindowController {
    convenience init() {
        HarnessChrome.update(
            themeName: SessionCoordinator.shared.snapshot.themeName,
            opacity: CGFloat(SessionCoordinator.shared.settings.backgroundOpacity),
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

    /// Re-reads opacity/blur from settings and applies to the window.
    /// The actual blur is rendered by per-area `ChromeBackdrop` views inside the
    /// content; the window itself just needs to be non-opaque so they show.
    func applyTransparency() {
        guard let window else { return }
        let opacity = max(0, min(1, SessionCoordinator.shared.settings.backgroundOpacity))
        let isOpaque = opacity >= 0.999

        window.titlebarAppearsTransparent = SessionCoordinator.shared.settings.transparentTitlebar
        window.isOpaque = isOpaque
        window.backgroundColor = isOpaque ? HarnessChrome.current.terminalBackground : .clear

        // Make sure the content view paints transparent so backdrops show through.
        if let content = window.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
