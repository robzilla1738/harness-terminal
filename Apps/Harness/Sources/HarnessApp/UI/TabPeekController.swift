import AppKit
import HarnessCore
import HarnessTerminalKit

/// A window-attached tab drawer. Thumbnails never resize or acquire terminal PTYs.
@MainActor
enum TabPeekController {
    private static var model = TabPeek(rows: 0, columns: 0)
    private static var panel: KeyablePanel?
    private static weak var parent: NSWindow?
    private static weak var context: WindowContext?
    private static var keyView: TabPeekKeyView?
    private static var observers: [NSObjectProtocol] = []
    private static var clickMonitor: Any?
    private static var generation = 0
    private static var displayedTabs: [TabPeek.Tab]?

    static func toggle(relativeTo window: NSWindow? = nil) {
        if panel != nil { close(); return }
        guard let window = window ?? NSApp.keyWindow ?? NSApp.mainWindow,
              let context = WindowContexts.all.first(where: { $0.window === window }) else { return }
        parent = window
        self.context = context
        let host = context.tab?.rootPane.allSurfaceIDs().first.flatMap { SessionCoordinator.shared.terminalHostIfExists(for: $0) }
        let size = host?.gridCellCount ?? (rows: 24, columns: 80)
        model = TabPeek(rows: size.rows, columns: size.columns, tabs: loadTabs())
        model.toggle()
        if let active = context.tab?.id.uuidString { model.select(id: active) }
        let view = TabPeekKeyView()
        let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.contentView = view
        panel.setAccessibilityLabel("Tab Peek")
        self.panel = panel; keyView = view
        refresh()
        position()
        window.addChildWindow(panel, ordered: .above)
        let destination = panel.frame
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduced {
            panel.alphaValue = 0
            panel.setFrameOrigin(NSPoint(x: destination.minX + 14, y: destination.minY))
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
        if !reduced {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = HarnessDesign.Motion.fast
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(destination, display: true)
            }
        }
        let nc = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { position() }
            })
        }
        for (name, object) in [(NSWindow.willCloseNotification, window as AnyObject),
                               (NSWindow.willMiniaturizeNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            observers.append(nc.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { close(restoreFocus: false) }
            })
        }
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { close(restoreFocus: false) }
        })
        observers.append(nc.addObserver(forName: NotificationBus.shared.snapshotChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refresh() }
        })
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated { if event.window !== self.panel { close(restoreFocus: false) } }
            return event
        }
    }

    static func move(_ delta: Int) { model.move(delta: delta); keyView?.select(selectedID) }
    private static var selectedID: String? { model.tabs.indices.contains(model.selection) ? model.tabs[model.selection].id : nil }

    static func close(restoreFocus: Bool = true) {
        guard let panel else { return }
        generation += 1
        let window = parent
        observers.forEach(NotificationCenter.default.removeObserver(_:)); observers = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; clickMonitor = nil
        self.panel = nil; keyView = nil; parent = nil; context = nil
        model = TabPeek(rows: 0, columns: 0)
        displayedTabs = nil
        panel.ignoresMouseEvents = true
        if restoreFocus, window?.isVisible == true { window?.makeKey() }
        let finish: @MainActor @Sendable () -> Void = {
            window?.removeChildWindow(panel)
            panel.orderOut(nil); panel.contentView = nil
        }
        if !restoreFocus || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = 0.12
                animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: { MainActor.assumeIsolated { finish() } }
        }
    }

    static func activateSelection() { if let selectedID { activate(selectedID) } }
    static func activate(_ id: String) {
        guard let context, let workspace = context.workspace, let uuid = UUID(uuidString: id),
              context.session?.tabs.contains(where: { $0.id == uuid }) == true else { close(); return }
        let window = parent
        close()
        window?.makeKey()
        SessionCoordinator.shared.selectTab(workspaceID: workspace.id, tabID: uuid)
    }

    private static func loadTabs() -> [TabPeek.Tab] {
        (context?.session?.tabs ?? []).map { tab in
            let base = SurfaceIdentity.label(directory: tab.cwd, program: tab.currentCommand, agent: tab.agent?.kind.commandToken)
            return TabPeek.Tab(id: tab.id.uuidString, title: TabChip.title(base: base, app: tab.programMark?.app), layout: tab.rootPane, mark: tab.programMark)
        }
    }

    private static func refresh() {
        guard let view = keyView else { return }
        let tabs = loadTabs()
        let changed = displayedTabs != tabs
        displayedTabs = tabs
        model.replaceTabs(tabs)
        view.show(tabs, selected: selectedID)
        position()
        guard changed else { return }
        generation += 1
        let ticket = generation
        TabThumbnailView.capture(view.capturedSurfaces) { [weak view] captures in
            guard ticket == generation, panel != nil else { return }
            view?.show(captures)
        }
    }

    private static func position() {
        guard let panel, let parent, let view = keyView else { return }
        // Inside the trailing edge: remains usable at screen edges and never changes the PTY grid.
        let frame = parent.frame
        let width = min(320, max(240, frame.width - 32))
        let height = min(view.preferredHeight(width: width), max(120, frame.height - HarnessDesign.tabBarHeight - 32))
        panel.setFrame(NSRect(x: frame.maxX - width - 16,
                              y: frame.maxY - HarnessDesign.tabBarHeight - 16 - height,
                              width: width, height: height), display: true)
    }
}

@MainActor
private final class TabPeekKeyView: NSView {
    private let scroll = NSScrollView()
    private let list = FlippedListView()
    private let title = NSTextField(labelWithString: "Tab Peek")
    private let hint = NSTextField(labelWithString: "↑ ↓ to choose · Return to open · Esc to close")
    private let empty = NSTextField(labelWithString: "No tabs available")
    private let closeButton = HarnessPillButton(title: "Close", kind: .secondary)
    private var rows: [TabPeekRowView] = []
    private var rowsByID: [String: TabPeekRowView] = [:]
    private var tabs: [TabPeek.Tab] = []
    private static let inset: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.panel
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        hint.font = .systemFont(ofSize: 10)
        empty.font = .systemFont(ofSize: 12)
        closeButton.target = self; closeButton.action = #selector(dismiss)
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = list
        for child in [title, hint, closeButton, scroll, empty] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            title.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            empty.topAnchor.constraint(equalTo: scroll.topAnchor),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    @objc private func dismiss() { TabPeekController.close() }
    var capturedSurfaces: [SurfaceID] { rows.flatMap(\.preview.capturedSurfaces) }
    func preferredHeight(width: CGFloat) -> CGFloat {
        let rowHeight = TabPeekRowView.height(forWidth: width - 2 * Self.inset)
        return 80 + max(36, CGFloat(rows.count) * (rowHeight + 12) - 12)
    }
    func show(_ tabs: [TabPeek.Tab], selected: String?) {
        if self.tabs != tabs {
            let old = Dictionary(uniqueKeysWithValues: self.tabs.map { ($0.id, $0) })
            rows.forEach { $0.removeFromSuperview() }
            rows = tabs.map { tab in
                let row = old[tab.id] == tab ? rowsByID[tab.id] ?? TabPeekRowView(tab: tab) : TabPeekRowView(tab: tab)
                list.addSubview(row)
                return row
            }
            self.tabs = tabs
            rowsByID = Dictionary(uniqueKeysWithValues: zip(tabs.map(\.id), rows))
        }
        let chrome = HarnessChrome.current
        appearance = NSAppearance(named: chrome.isDark ? .darkAqua : .aqua)
        layer?.backgroundColor = chrome.sidebarBackground.cgColor
        layer?.borderColor = chrome.borderStrong.cgColor
        title.textColor = chrome.textPrimary; hint.textColor = chrome.textSecondary; empty.textColor = chrome.textSecondary
        empty.isHidden = !rows.isEmpty
        select(selected)
    }
    func select(_ id: String?) {
        for (key, row) in rowsByID { row.setSelected(key == id) }
        needsLayout = true; layoutSubtreeIfNeeded()
        if let id, let row = rowsByID[id] { list.scrollToVisible(row.frame) }
    }
    func show(_ captures: [SurfaceID: TerminalThumbnail]) { rows.forEach { $0.preview.show(captures) } }
    override func layout() {
        super.layout()
        let width = scroll.contentSize.width
        let height = TabPeekRowView.height(forWidth: width)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * (height + 12), width: width, height: height)
        }
        list.frame = NSRect(x: 0, y: 0, width: width, height: max(CGFloat(rows.count) * (height + 12) - 12, 0))
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: TabPeekController.move(-1)
        case 124, 125: TabPeekController.move(1)
        case 53: TabPeekController.close()
        case 36: TabPeekController.activateSelection()
        default: super.keyDown(with: event)
        }
    }
    override func cancelOperation(_ sender: Any?) { TabPeekController.close() }
}

private final class FlippedListView: NSView { override var isFlipped: Bool { true } }

@MainActor
private final class TabPeekRowView: NSView {
    let preview: TabThumbnailView
    private let title = NSTextField(labelWithString: "")
    private let id: String
    static func height(forWidth width: CGFloat) -> CGFloat { (28 + width * 0.5).rounded() }
    init(tab: TabPeek.Tab) {
        id = tab.id
        preview = TabThumbnailView(root: tab.layout)
        super.init(frame: .zero)
        let badge = TabPeek.badge(tab.mark)
        title.stringValue = tab.title + (badge.isEmpty ? "" : " · \(badge)")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.card; layer?.cornerCurve = .continuous
        preview.wantsLayer = true
        preview.layer?.cornerRadius = HarnessDesign.Radius.control; preview.layer?.masksToBounds = true
        for child in [title, preview] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.heightAnchor.constraint(equalToConstant: 16),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            preview.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title.stringValue)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    func setSelected(_ selected: Bool) {
        let chrome = HarnessChrome.current
        title.textColor = selected ? chrome.textPrimary : chrome.textSecondary
        layer?.backgroundColor = (selected ? chrome.rowSelectedFill : chrome.surfaceElevated).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (selected ? chrome.focusRing : chrome.border).cgColor
        setAccessibilityValue(selected ? "Selected" : "")
    }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { TabPeekController.activate(id) }
    override func accessibilityPerformPress() -> Bool { TabPeekController.activate(id); return true }
}
