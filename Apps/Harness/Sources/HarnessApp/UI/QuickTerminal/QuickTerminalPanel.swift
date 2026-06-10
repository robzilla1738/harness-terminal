import AppKit

/// The Quake-style dropdown window: borderless, floats above everything, and joins all Spaces.
/// Unlike `NotchPanel`, it **can become key** so the hosted terminal surface receives keystrokes.
@MainActor
final class QuickTerminalPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.nonactivatingPanel` lets it appear without yanking activation away from a full-screen
            // app's Space; `show()` still activates Harness + makes the panel key so typing lands here.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
