import AppKit
import HarnessCore

/// Workspace Overview (View ▸ Workspace Overview, ⌘⇧O): every tab as a live tile over the
/// window, anything waiting on you first. Type to filter, arrows to move, ↩ to open, Esc to
/// close. Each tile draws the tab's panes live with the terminal renderer (`TabThumbnailView`);
/// opening and refreshing never create a terminal view or resize a PTY.
@MainActor
enum WorkspaceOverviewController {
    private static var panel: KeyablePanel?

    static func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    static func close() {
        (panel?.contentView as? OverviewView)?.stop()
        panel?.orderOut(nil)
        panel = nil
    }

    private static func show() {
        guard let parent = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let window = KeyablePanel(
            contentRect: parent.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        let view = OverviewView(frame: NSRect(origin: .zero, size: parent.frame.size))
        view.onClose = { close() }
        window.contentView = view
        window.delegate = view
        window.setFrame(parent.frame, display: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view.filterField)
        panel = window
    }
}

@MainActor
private final class OverviewView: NSView, NSTextFieldDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?
    let filterField = NSTextField()
    private let backdrop = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let grid = FlippedGridView()
    private let empty = NSTextField(labelWithString: "No tabs match")
    private var all: [OverviewTab] = []
    private var shown: [OverviewTab] = []
    private var tiles: [OverviewTileView] = []
    /// Every tab's tile, kept across filtering so a tab's thumbnail isn't rebuilt per keystroke.
    private var tilesByID: [String: OverviewTileView] = [:]
    private var selected = 0
    private var columns = 3
    private var timer: Timer?
    private var capturing = false

    private static let tileMinWidth: CGFloat = 300
    private static let gap: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let c = HarnessChrome.current
        appearance = NSAppearance(named: c.isDark ? .darkAqua : .aqua)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = HarnessDesign.Radius.panel
        backdrop.layer?.masksToBounds = true
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = c.terminalBackground.withAlphaComponent(0.78).cgColor

        filterField.isBezeled = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.font = .systemFont(ofSize: 15, weight: .medium)
        filterField.textColor = c.textPrimary
        filterField.alignment = .center
        filterField.placeholderAttributedString = NSAttributedString(
            string: "Filter tabs…",
            attributes: [.foregroundColor: c.textTertiary, .font: NSFont.systemFont(ofSize: 15, weight: .medium)]
        )
        filterField.delegate = self
        filterField.setAccessibilityLabel("Filter tabs")

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid

        empty.textColor = c.textTertiary
        empty.font = .systemFont(ofSize: 13)
        empty.isHidden = true

        for view in [backdrop, tint, filterField, scroll, empty] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let pad = HarnessDesign.Spacing.xxl
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            filterField.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            filterField.centerXAnchor.constraint(equalTo: centerXAnchor),
            filterField.widthAnchor.constraint(equalToConstant: 360),
            scroll.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: pad),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        all = WorkspaceOverviewBuilder.tabs(from: SessionCoordinator.shared.snapshot)
        rebuild(selectActive: true)
        refreshCaptures()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCaptures() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Stops the capture refresh, and the live thumbnails with their tiles.
    func stop() {
        timer?.invalidate()
        timer = nil
        tiles.forEach { $0.removeFromSuperview() }
    }

    override func layout() {
        super.layout()
        layoutGrid()
    }

    // MARK: - Tiles

    private func rebuild(selectActive: Bool = false) {
        shown = WorkspaceOverviewBuilder.ordered(all, query: filterField.stringValue)
        tiles.forEach { $0.removeFromSuperview() }
        tiles = shown.enumerated().map { index, tab in
            let tile = tilesByID[tab.id] ?? OverviewTileView(tab: tab)
            tilesByID[tab.id] = tile
            tile.onClick = { [weak self] in self?.open(index) }
            tile.onHover = { [weak self] in self?.select(index) }
            grid.addSubview(tile)
            return tile
        }
        if selectActive, let active = shown.firstIndex(where: \.active) {
            selected = shown.first?.needsYou == true ? 0 : active
        } else {
            selected = min(selected, max(shown.count - 1, 0))
        }
        empty.isHidden = !shown.isEmpty
        updateSelection()
        needsLayout = true
    }

    private func layoutGrid() {
        let width = scroll.contentSize.width
        guard width > 0 else { return }
        columns = max(1, Int((width + Self.gap) / (Self.tileMinWidth + Self.gap)))
        let tileWidth = floor((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns))
        let tileHeight = OverviewTileView.height(forWidth: tileWidth)
        for (index, tile) in tiles.enumerated() {
            let row = index / columns
            let column = index % columns
            tile.frame = NSRect(
                x: CGFloat(column) * (tileWidth + Self.gap),
                y: CGFloat(row) * (tileHeight + Self.gap),
                width: tileWidth,
                height: tileHeight
            )
        }
        let rows = (tiles.count + columns - 1) / columns
        grid.frame = NSRect(x: 0, y: 0, width: width, height: max(CGFloat(rows) * (tileHeight + Self.gap) - Self.gap, 0))
    }

    private func select(_ index: Int) {
        guard index != selected, tiles.indices.contains(index) else { return }
        selected = index
        updateSelection()
    }

    private func updateSelection() {
        for (index, tile) in tiles.enumerated() { tile.setSelected(index == selected) }
        if tiles.indices.contains(selected) { grid.scrollToVisible(tiles[selected].frame.insetBy(dx: 0, dy: -Self.gap)) }
    }

    private func open(_ index: Int) {
        guard shown.indices.contains(index),
              let session = UUID(uuidString: shown[index].sessionID),
              let tab = UUID(uuidString: shown[index].id)
        else { return }
        let coordinator = SessionCoordinator.shared
        onClose?()
        guard let workspace = coordinator.snapshot.activeWorkspaceID else { return }
        coordinator.selectSession(workspaceID: workspace, sessionID: session)
        coordinator.selectTab(workspaceID: workspace, tabID: tab)
    }

    // MARK: - Captures

    /// Panes with a terminal draw themselves live; the rest refresh from the daemon's capture.
    private func refreshCaptures() {
        guard !capturing else { return }
        capturing = true
        TabThumbnailView.capture(tiles.flatMap(\.preview.capturedSurfaces)) { [weak self] captures in
            guard let self else { return }
            capturing = false
            tiles.forEach { $0.preview.show(captures) }
        }
    }

    // MARK: - Keys

    func controlTextDidChange(_ obj: Notification) {
        selected = 0
        rebuild()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let count = tiles.count
        switch selector {
        case #selector(NSResponder.moveLeft(_:)) where filterField.stringValue.isEmpty:
            select(WorkspaceOverviewBuilder.move(from: selected, by: -1, count: count))
        case #selector(NSResponder.moveRight(_:)) where filterField.stringValue.isEmpty:
            select(WorkspaceOverviewBuilder.move(from: selected, by: 1, count: count))
        case #selector(NSResponder.moveUp(_:)):
            select(WorkspaceOverviewBuilder.move(from: selected, by: -columns, count: count))
        case #selector(NSResponder.moveDown(_:)):
            select(WorkspaceOverviewBuilder.move(from: selected, by: columns, count: count))
        case #selector(NSResponder.insertTab(_:)):
            select((selected + 1) % max(count, 1))
        case #selector(NSResponder.insertNewline(_:)):
            open(selected)
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
        default:
            return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        onClose?()
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the backdrop, not a tile, closes.
        onClose?()
    }
}

private final class FlippedGridView: NSView {
    override var isFlipped: Bool { true }
}

/// One tab: icon tile, identity, session, a "Needs you" badge, and its panes drawn live.
@MainActor
private final class OverviewTileView: NSView {
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    let preview: TabThumbnailView
    private let tile = IconTileView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "Needs you")

    private static let inset = HarnessDesign.Spacing.lg
    /// Preview height over width: about a terminal window's shape.
    private static let previewAspect: CGFloat = 0.6

    /// A tile's height at `width`: the header row, then a window-shaped preview.
    static func height(forWidth width: CGFloat) -> CGFloat {
        (3 * inset + HarnessDesign.iconTileSize + (width - 2 * inset) * previewAspect).rounded()
    }

    init(tab: OverviewTab) {
        preview = TabThumbnailView(root: tab.layout)
        super.init(frame: .zero)
        let c = HarnessChrome.current
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = c.terminalBackground.withAlphaComponent(0.9).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = c.borderStrong.cgColor

        tile.apply(IconTileView.content(for: tab.agent))
        title.stringValue = tab.title
        title.font = HarnessDesign.Typography.sidebarLabel
        title.textColor = c.textPrimary
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let paneNote = tab.panes.count > 1 ? "\(tab.panes.count) panes" : ""
        subtitle.stringValue = [tab.sessionName, paneNote].filter { !$0.isEmpty }.joined(separator: " · ")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = c.textTertiary
        badge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        badge.textColor = c.attention
        badge.isHidden = !tab.needsYou

        for view in [tile, title, subtitle, badge, preview] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let inset = Self.inset
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            tile.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            title.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HarnessDesign.Spacing.md),
            title.topAnchor.constraint(equalTo: topAnchor, constant: inset - 2),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -HarnessDesign.Spacing.sm),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            badge.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            preview.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: inset),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel([tab.title, tab.sessionName, tab.needsYou ? "needs you" : ""].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        let c = HarnessChrome.current
        layer?.borderWidth = selected ? 2 : 1
        layer?.borderColor = (selected ? c.accent : c.borderStrong).cgColor
        setAccessibilitySelected(selected)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}
