import AppKit

/// Borderless panel that can still take key focus, so a filter field or arrow keys reach it.
/// A plain borderless `NSPanel` refuses key status and keystrokes fall through to the terminal.
@MainActor
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
