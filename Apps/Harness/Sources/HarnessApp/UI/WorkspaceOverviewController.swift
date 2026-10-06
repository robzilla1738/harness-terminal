import AppKit
import HarnessCore

/// Keyboard overview (View ▸ Workspace Overview, ⌘⇧O). Thumbnails are labels
/// drawn from the session snapshot. Opening and refreshing never resize a PTY.
@MainActor
enum WorkspaceOverviewController {
    private static var overview = WorkspaceOverview(rows: 24, cols: 80)
    private static var panel: NSPanel?

    static func toggle() {
        WorkspaceOverviewBuilder.toggle(&overview, snapshot: SessionCoordinator.shared.snapshot)
        if overview.isOpen {
            show(overview)
        } else {
            panel?.close()
        }
    }

    private static func show(_ overview: WorkspaceOverview) {
        let text = overview.tabs.map { tab in
            let panes = tab.panes.map(\.liveText).joined(separator: "\n    ")
            return "\(tab.title)\n    \(panes)"
        }.joined(separator: "\n\n")
        let chrome = HarnessChrome.current
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        view.string = text.isEmpty ? "No tabs" : text
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.drawsBackground = true
        view.backgroundColor = chrome.sidebarBackground
        view.textColor = chrome.textPrimary
        view.insertionPointColor = chrome.textPrimary
        view.textContainerInset = NSSize(width: 14, height: 14)
        let appearance = NSAppearance(named: chrome.isDark ? .darkAqua : .aqua)
        if panel == nil {
            let window = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            window.title = "Workspace Overview"
            window.isFloatingPanel = true
            panel = window
        }
        panel?.appearance = appearance
        panel?.backgroundColor = chrome.sidebarBackground
        panel?.contentView = view
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
    }
}
