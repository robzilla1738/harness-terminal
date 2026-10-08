import AppKit
import HarnessCore
import HarnessTerminalKit

/// Tab peek from a key (⌃⌘P) or a horizontal swipe on the tab bar: each tab's panes drawn
/// live (`TabThumbnailView`). Reads the live grid size and never writes it.
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
            hide()
            return
        }
        present(reduceMotion: reduceMotion)
    }

    static func move(_ delta: Int) {
        model.move(delta: delta)
        refresh()
    }

    static func close() {
        if model.phase != .closed { model.toggle(reduceMotion: false) }
        while model.phase != .closed { model.toggle(reduceMotion: false) }
        hide()
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
            return TabPeek.Tab(
                id: tab.id.uuidString,
                title: TabChip.title(base: base, app: tab.programMark?.app),
                layout: tab.rootPane,
                mark: tab.programMark
            )
        }
    }

    /// The thumbnails stop with their rows.
    private static func hide() {
        panel?.orderOut(nil)
        keyView?.clear()
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
        refresh()
        // Panes without a terminal in this app show the daemon's capture, fetched off the main thread.
        TabThumbnailView.capture(view.capturedSurfaces) { captures in
            guard model.phase != .closed else { return }
            view.show(captures)
        }
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
                context.duration = HarnessDesign.Motion.fast
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

    private static func refresh() {
        let visible: [TabPeek.Tab]
        if model.phase == .peeking, let active = SessionCoordinator.shared.snapshot.activeWorkspace?.activeTabID?.uuidString {
            visible = model.tabs.filter { $0.id != active }
        } else {
            visible = model.tabs
        }
        let selected = model.tabs.indices.contains(model.selection) ? model.tabs[model.selection].id : nil
        keyView?.show(visible, selected: selected)
    }
}

@MainActor
private final class TabPeekKeyView: NSView {
    private let scroll = NSScrollView()
    private let list = FlippedListView()
    private let empty = NSTextField(labelWithString: "No other tabs")
    private var rows: [TabPeekRowView] = []
    /// Every tab's row while the peek is open, kept across steps so a thumbnail isn't rebuilt.
    private var rowsByID: [String: TabPeekRowView] = [:]

    private static let inset: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        empty.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        empty.textColor = .labelColor
        for view in [scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            empty.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Panes in the shown tabs with no terminal in this app: they need captures.
    var capturedSurfaces: [SurfaceID] { rows.flatMap(\.preview.capturedSurfaces) }

    func show(_ tabs: [TabPeek.Tab], selected: String?) {
        rows.forEach { $0.removeFromSuperview() }
        rows = tabs.map { tab in
            let row = rowsByID[tab.id] ?? TabPeekRowView(tab: tab)
            rowsByID[tab.id] = row
            row.setSelected(tab.id == selected)
            list.addSubview(row)
            return row
        }
        empty.isHidden = !rows.isEmpty
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let row = rows.first(where: \.isSelected) { list.scrollToVisible(row.frame) }
    }

    func show(_ captures: [SurfaceID: TerminalThumbnail]) {
        rows.forEach { $0.preview.show(captures) }
    }

    func clear() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        rowsByID = [:]
    }

    override func layout() {
        super.layout()
        let width = scroll.contentSize.width
        let height = TabPeekRowView.height(forWidth: width)
        let gap = HarnessDesign.Spacing.lg
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * (height + gap), width: width, height: height)
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(CGFloat(rows.count) * (height + gap) - gap, 0))
    }

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

private final class FlippedListView: NSView {
    override var isFlipped: Bool { true }
}

/// One tab in the peek: its title (and attention badge) over its panes, drawn live.
@MainActor
private final class TabPeekRowView: NSView {
    let preview: TabThumbnailView
    private let title = NSTextField(labelWithString: "")
    private(set) var isSelected = false

    private static let titleHeight: CGFloat = 16
    /// Preview height over width: about a terminal window's shape, a little flatter to fit more.
    private static let previewAspect: CGFloat = 0.5

    static func height(forWidth width: CGFloat) -> CGFloat {
        (titleHeight + HarnessDesign.Spacing.xs + width * previewAspect).rounded()
    }

    init(tab: TabPeek.Tab) {
        preview = TabThumbnailView(root: tab.layout)
        super.init(frame: .zero)
        let badge = TabPeek.badge(tab.mark)
        title.stringValue = tab.title + (badge.isEmpty ? "" : " [\(badge)]")
        title.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        title.lineBreakMode = .byTruncatingMiddle
        preview.wantsLayer = true
        preview.layer?.cornerRadius = HarnessDesign.Radius.control
        preview.layer?.cornerCurve = .continuous
        for view in [title, preview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            title.topAnchor.constraint(equalTo: topAnchor),
            title.heightAnchor.constraint(equalToConstant: Self.titleHeight),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: HarnessDesign.Spacing.xs),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        title.textColor = selected ? .labelColor : .secondaryLabelColor
        preview.layer?.borderWidth = selected ? 2 : 0
        preview.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
