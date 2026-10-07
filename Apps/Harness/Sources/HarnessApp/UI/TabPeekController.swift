import AppKit
import HarnessCore

/// Tab peek from a key (⌃⌘P) or a horizontal swipe on the tab bar.
/// Reads the live grid size and never writes it.
@MainActor
enum TabPeekController {
    private static var model = TabPeek(rows: 0, columns: 0)
    private static var panel: NSPanel?
    private static var keyView: TabPeekKeyView?

    static func toggle() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if model.phase == .closed {
            let size = liveGridSize()
            model = TabPeek(rows: size.rows, columns: size.columns, tabs: loadTabs())
        }
        model.toggle(reduceMotion: reduceMotion)
        if model.phase == .closed {
            panel?.orderOut(nil)
            return
        }
        present(reduceMotion: reduceMotion)
    }

    static func move(_ delta: Int) {
        model.move(delta: delta)
        refreshText()
    }

    static func close() {
        if model.phase != .closed { model.toggle(reduceMotion: false) }
        while model.phase != .closed { model.toggle(reduceMotion: false) }
        panel?.orderOut(nil)
    }

    static func activateSelection() {
        guard model.tabs.indices.contains(model.selection) else { return }
        let id = model.tabs[model.selection].id
        guard let uuid = UUID(uuidString: id),
              let workspaceID = SessionCoordinator.shared.snapshot.activeWorkspaceID
        else { return }
        SessionCoordinator.shared.selectTab(workspaceID: workspaceID, tabID: uuid)
        close()
    }

    private static func liveGridSize() -> (rows: Int, columns: Int) {
        let coordinator = SessionCoordinator.shared
        guard let surfaceID = coordinator.activeSurfaceID,
              let host = coordinator.terminalHostIfExists(for: surfaceID)
        else { return (24, 80) }
        return host.gridCellCount
    }

    private static func loadTabs() -> [TabPeek.Tab] {
        let coordinator = SessionCoordinator.shared
        let tabs = coordinator.snapshot.activeWorkspace?.tabs ?? []
        return tabs.map { tab in
            let base = SurfaceIdentity.label(
                directory: tab.cwd,
                program: tab.currentCommand,
                agent: tab.agent?.kind.commandToken
            )
            let preview = tab.rootPane.allSurfaceIDs().compactMap { surfaceID -> String? in
                guard case let .text(text)? = coordinator.requestDaemon(
                    .capturePane(surfaceID: surfaceID.uuidString, includeScrollback: false)
                ) else { return nil }
                return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(6).joined(separator: "\n")
            }.joined(separator: "\n")
            return TabPeek.Tab(
                id: tab.id.uuidString,
                title: TabChip.title(base: base, app: tab.programMark?.app),
                preview: preview,
                mark: tab.programMark
            )
        }
    }

    private static func present(reduceMotion: Bool) {
        let view = keyView ?? TabPeekKeyView()
        keyView = view
        if panel == nil {
            let panel = KeyablePanel(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.contentView = view
            self.panel = panel
        }
        refreshText()
        guard let panel, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let size = model.phase == .overview
            ? NSSize(width: 520, height: 460)
            : NSSize(width: 280, height: 360)
        let destination: NSPoint
        if model.phase == .peeking {
            destination = NSPoint(x: window.frame.maxX - size.width - 12, y: window.frame.midY - size.height / 2)
        } else {
            destination = NSPoint(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2)
        }
        let start = NSPoint(x: window.frame.maxX, y: destination.y)
        panel.setContentSize(size)
        if reduceMotion || model.phase == .overview {
            panel.setFrameOrigin(destination)
        } else {
            panel.setFrameOrigin(start)
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().setFrameOrigin(destination)
            }
            panel.makeKey()
            panel.makeFirstResponder(view)
            return
        }
        panel.orderFront(nil)
        panel.makeKey()
        panel.makeFirstResponder(view)
    }

    private static func refreshText() {
        let visible: [TabPeek.Tab]
        if model.phase == .peeking, let active = SessionCoordinator.shared.snapshot.activeWorkspace?.activeTabID?.uuidString {
            visible = model.tabs.filter { $0.id != active }
        } else {
            visible = model.tabs
        }
        let body = visible.enumerated().map { index, tab in
            let marker = model.tabs.firstIndex(where: { $0.id == tab.id }) == model.selection ? "> " : "  "
            let badge = TabPeek.badge(tab.mark)
            let badgeText = badge.isEmpty ? "" : " [\(badge)]"
            let preview = tab.preview.isEmpty ? "" : "\n" + tab.preview
            return "\(marker)\(tab.title)\(badgeText)\(preview)"
        }.joined(separator: "\n\n")
        keyView?.text.stringValue = body.isEmpty ? "No other tabs" : body
    }
}

@MainActor
private final class TabPeekKeyView: NSView {
    let text = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = 10
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.maximumNumberOfLines = 0
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: TabPeekController.move(-1)
        case 124, 126: TabPeekController.move(1)
        case 53: TabPeekController.close()
        case 36: TabPeekController.activateSelection()
        default: super.keyDown(with: event)
        }
    }
}
