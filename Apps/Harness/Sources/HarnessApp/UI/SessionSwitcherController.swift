import AppKit
import HarnessCore

/// The sessions popover: a "Filter or create…" field, sessions (✓ on the current one,
/// grouped by daemon when there are several), then New Session and Add Remote Host.
/// Drops down from the title-bar sessions button, or centers on the window from the
/// palette / ⌃⌘S. ↑↓ move, ↩ opens, Esc or a click outside closes.
@MainActor
enum SessionSwitcherController {
    private static var panel: KeyablePanel?

    static var isShown: Bool { panel?.isVisible == true }

    static func toggle(relativeTo parent: NSWindow?, anchor: NSView? = nil) {
        // Clicking the sessions button to dismiss first resigns the panel (closing it),
        // then fires the button; don't read that second half as "open again".
        if isShown || Date().timeIntervalSince(lastClosed) < 0.3 { close() } else { present(relativeTo: parent, anchor: anchor) }
    }

    private static var lastClosed = Date.distantPast

    static func present(relativeTo parent: NSWindow?, anchor: NSView? = nil) {
        close()
        let content = SessionSwitcherView()
        let window = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.contentView = content
        window.setContentSize(content.fittingSize)
        if let anchor, let anchorWindow = anchor.window {
            // Drop down from the button, left edges aligned.
            let rect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            window.setFrameTopLeftPoint(NSPoint(x: rect.minX - HarnessDesign.Spacing.xs, y: rect.minY - HarnessDesign.Spacing.xs))
        } else if let parent {
            let frame = parent.frame
            let size = window.frame.size
            window.setFrameTopLeftPoint(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height / 4))
        }
        content.onClose = { close() }
        content.onResize = { [weak window] size in
            guard let window else { return }
            let top = window.frame.maxY
            window.setContentSize(size)
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: top))
        }
        window.delegate = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content.filterField)
        panel = window
    }

    static func close() {
        if panel != nil { lastClosed = Date() }
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
private final class SessionSwitcherView: NSView, NSTextFieldDelegate, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onResize: ((NSSize) -> Void)?
    let filterField = NSTextField()

    private let width: CGFloat = 300
    private let rowHeight: CGFloat = 28
    private let maxVisibleRows = 12
    private let background = NSVisualEffectView()
    private let tint = NSView()
    private let filterBox = NSView()
    private let filterIcon = NSImageView()
    private let list = FlippedView()
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private var items: [SwitcherItem] = []
    private var sessions: [SwitcherSession] = []
    private var currentID: String?
    /// Each session's most urgent tab mark (needs you, error, done, working), on any machine.
    private var statuses: [String: TabActivity] = [:]
    private var selectedIndex: Int?
    /// The session being renamed in the filter field (⌘R or a right-click), else nil.
    private var renaming: SwitcherSession?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let c = HarnessChrome.current
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.panel
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = c.borderStrong.cgColor
        appearance = NSAppearance(named: c.isDark ? .darkAqua : .aqua)

        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = c.terminalBackground.withAlphaComponent(0.72).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tint)

        filterBox.wantsLayer = true
        filterBox.layer?.cornerRadius = HarnessDesign.Radius.card
        filterBox.layer?.cornerCurve = .continuous
        filterBox.layer?.backgroundColor = c.rowHoverFill.cgColor
        filterBox.layer?.borderWidth = 1
        filterBox.layer?.borderColor = c.border.cgColor
        filterBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterBox)

        filterIcon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        filterIcon.contentTintColor = c.textTertiary
        filterIcon.translatesAutoresizingMaskIntoConstraints = false
        filterBox.addSubview(filterIcon)

        filterField.isBezeled = false
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.font = HarnessDesign.Typography.sidebarLabel
        filterField.textColor = c.textPrimary
        filterField.placeholderAttributedString = NSAttributedString(
            string: "Filter or create…",
            attributes: [.foregroundColor: c.textTertiary, .font: HarnessDesign.Typography.sidebarLabel]
        )
        filterField.delegate = self
        filterField.setAccessibilityLabel("Filter sessions, or type a name to create one")
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterBox.addSubview(filterField)

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = list
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let pad = HarnessDesign.Spacing.sm
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: rowHeight)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
            filterBox.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            filterBox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            filterBox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            filterBox.heightAnchor.constraint(equalToConstant: 30),
            filterIcon.leadingAnchor.constraint(equalTo: filterBox.leadingAnchor, constant: HarnessDesign.Spacing.md),
            filterIcon.centerYAnchor.constraint(equalTo: filterBox.centerYAnchor),
            filterField.leadingAnchor.constraint(equalTo: filterIcon.trailingAnchor, constant: HarnessDesign.Spacing.sm),
            filterField.trailingAnchor.constraint(equalTo: filterBox.trailingAnchor, constant: -HarnessDesign.Spacing.md),
            filterField.centerYAnchor.constraint(equalTo: filterBox.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: filterBox.bottomAnchor, constant: pad),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            scrollHeight,
        ])
        loadSessions()
        reload(resetSelection: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Data

    private func loadSessions() {
        let coordinator = SessionCoordinator.shared
        let workspace = coordinator.snapshot.activeWorkspace
        let here = RemoteHostsService.shared.activeHostName ?? DaemonSidebar.localID
        let hereTitle = here == DaemonSidebar.localID ? "This Mac" : here
        currentID = workspace?.activeSessionID?.uuidString
        statuses = [:]
        let urgency: [TabActivity] = [.blocked, .error, .done, .working]
        for owner in coordinator.connectedOwners {
            for session in coordinator.snapshot(for: owner).workspaces.flatMap(\.sessions) {
                let marks = Set(session.tabs.map(TabActivity.of))
                statuses[session.id.uuidString] = urgency.first(where: marks.contains) ?? TabActivity.none
            }
        }
        var list = (workspace?.sessions ?? []).map { session in
            SwitcherSession(id: session.id.uuidString, title: workspace.map { SessionDisplayName.title(of: session, in: $0) } ?? session.name, owner: here, ownerTitle: hereTitle)
        }
        // Sessions on the other attached daemons; picking one opens or focuses its window.
        for group in coordinator.sidebarGroups() {
            for row in group.sessions where row.owner != here {
                let owner = row.owner == DaemonSidebar.localID ? "This Mac" : row.owner
                list.append(SwitcherSession(id: row.id, title: row.name, owner: row.owner, ownerTitle: owner))
            }
        }
        sessions = list
    }

    /// A named session shows its name; an unnamed one shows what its active tab is doing.
    private func reload(resetSelection: Bool) {
        let query = filterField.stringValue
        items = SessionSwitcherModel.items(sessions: sessions, currentID: currentID, query: query)
        if resetSelection || selectedIndex.map({ !items.indices.contains($0) || items[$0].row == nil }) ?? true {
            selectedIndex = SessionSwitcherModel.initialSelection(items, query: query, currentID: currentID)
        }
        rebuildRows()
    }

    private func rebuildRows() {
        list.subviews.forEach { $0.removeFromSuperview() }
        var y: CGFloat = 0
        for (index, item) in items.enumerated() {
            let height: CGFloat
            let view: NSView
            switch item {
            case let .header(title):
                height = 22
                view = SwitcherHeaderView(title: title)
            case .separator:
                height = 9
                view = SwitcherSeparatorView()
            case let .row(row, owner):
                height = rowHeight
                let rowView = SwitcherRowView(row: row, symbol: Self.symbol(for: row.id, isSession: owner != nil),
                                              selected: index == selectedIndex, status: statuses[row.id] ?? .none)
                rowView.onHover = { [weak self] in self?.select(index) }
                rowView.onClick = { [weak self] in self?.activate(index) }
                rowView.onRename = { [weak self] in
                    self?.select(index)
                    self?.beginRename(index)
                }
                view = rowView
            }
            view.frame = NSRect(x: 0, y: y, width: width - HarnessDesign.Spacing.sm * 2, height: height)
            list.addSubview(view)
            y += height
        }
        list.frame = NSRect(x: 0, y: 0, width: width - HarnessDesign.Spacing.sm * 2, height: y)
        let visible = min(y, rowHeight * CGFloat(maxVisibleRows))
        scrollHeight.constant = max(visible, rowHeight)
        layoutSubtreeIfNeeded()
        onResize?(fittingSize)
        if let selectedIndex, let view = list.subviews[safe: selectedIndex] {
            list.scrollToVisible(view.frame)
        }
    }

    private static func symbol(for id: String, isSession: Bool) -> String? {
        if isSession { return nil }
        switch id {
        case SessionSwitcherModel.newSessionID: return "square.stack"
        case SessionSwitcherModel.addRemoteHostID: return "globe"
        case SessionSwitcherModel.createID: return "plus"
        default: return nil
        }
    }

    // MARK: - Selection

    private func select(_ index: Int) {
        guard index != selectedIndex, items[safe: index]?.row != nil else { return }
        selectedIndex = index
        for (i, view) in list.subviews.enumerated() {
            (view as? SwitcherRowView)?.setSelected(i == index)
        }
    }

    private func move(_ direction: Int) {
        guard let next = SessionSwitcherModel.step(items, from: selectedIndex, by: direction) else { return }
        select(next)
        if let view = list.subviews[safe: next] { list.scrollToVisible(view.frame) }
    }

    private func activate(_ index: Int?) {
        guard let index, case let .row(row, owner)? = items[safe: index] else { return }
        let coordinator = SessionCoordinator.shared
        let workspaceID = coordinator.snapshot.activeWorkspaceID
        onClose?()
        switch row.id {
        case SessionSwitcherModel.newSessionID:
            if let workspaceID { coordinator.addSession(to: workspaceID) }
        case SessionSwitcherModel.createID:
            let name = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let workspaceID { coordinator.addSession(to: workspaceID, name: name) }
        case SessionSwitcherModel.addRemoteHostID:
            MenuTarget.shared.addRemoteHost()
        default:
            coordinator.focusSidebar(owner: owner ?? DaemonSidebar.localID, sessionID: row.id)
        }
    }

    // MARK: - Rename

    /// Rename a session on this daemon in place: the filter field holds its name until
    /// Return saves it or Escape cancels.
    private func beginRename(_ index: Int?) {
        guard let index, case let .row(row, owner)? = items[safe: index], owner != nil,
              let session = sessions.first(where: { $0.id == row.id }),
              session.owner == (RemoteHostsService.shared.activeHostName ?? DaemonSidebar.localID)
        else { return }
        renaming = session
        filterField.stringValue = session.title
        setPlaceholder("Rename \(session.title)")
        filterField.currentEditor()?.selectAll(nil)
    }

    private func commitRename() {
        guard let session = renaming, let id = UUID(uuidString: session.id) else { return }
        let name = filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != session.title {
            SessionCoordinator.shared.requestDaemon(.renameSession(sessionID: id, name: name))
        }
        onClose?()
    }

    private func cancelRename() {
        renaming = nil
        filterField.stringValue = ""
        setPlaceholder("Filter or create…")
        reload(resetSelection: true)
    }

    private func setPlaceholder(_ text: String) {
        filterField.placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.foregroundColor: HarnessChrome.current.textTertiary, .font: HarnessDesign.Typography.sidebarLabel]
        )
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "r" {
            beginRename(selectedIndex)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Keys and dismissal

    func controlTextDidChange(_ obj: Notification) {
        guard renaming == nil else { return }
        reload(resetSelection: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if renaming != nil {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): commitRename()
            case #selector(NSResponder.cancelOperation(_:)): cancelRename()
            default: return false
            }
            return true
        }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): activate(selectedIndex)
        case #selector(NSResponder.cancelOperation(_:)): onClose?()
        default: return false
        }
        return true
    }

    func windowDidResignKey(_ notification: Notification) {
        onClose?()
    }
}

/// Top-down coordinates for the row list.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SwitcherRowView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    /// Right-click: rename this session in the filter field.
    var onRename: (() -> Void)?
    private let check = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let status = TabStatusView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private var selected: Bool
    private let isCurrent: Bool

    init(row: ChromeMenuRow, symbol: String?, selected: Bool, status activity: TabActivity = .none) {
        self.selected = selected
        isCurrent = row.current
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        check.isHidden = !row.current
        icon.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
        icon.isHidden = symbol == nil
        label.stringValue = row.title
        label.font = HarnessDesign.Typography.sidebarLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcut.stringValue = row.shortcut
        shortcut.font = HarnessDesign.Typography.sidebarLabel
        shortcut.alignment = .right
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.apply(activity, tint: HarnessChrome.current.accent)
        for view in [check, icon, label, status, shortcut] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let leading = HarnessDesign.Spacing.md
        let glyphColumn: CGFloat = 16
        NSLayoutConstraint.activate([
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: glyphColumn),
            icon.centerXAnchor.constraint(equalTo: check.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: HarnessDesign.Spacing.sm),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -HarnessDesign.Spacing.sm),
            status.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -HarnessDesign.Spacing.sm),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: activity == .none ? 0 : 12),
            status.heightAnchor.constraint(equalToConstant: 12),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -leading),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        let state = TabStatusView.label(activity).map { ", \($0)" } ?? ""
        setAccessibilityLabel((row.current ? "\(row.title), current session" : row.title) + state)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSelected(_ selected: Bool) {
        guard selected != self.selected else { return }
        self.selected = selected
        applyColors()
    }

    private func applyColors() {
        let c = HarnessChrome.current
        layer?.backgroundColor = selected ? c.accent.cgColor : NSColor.clear.cgColor
        let ink = selected ? Self.ink(on: c.accent) : c.textPrimary
        label.textColor = ink
        check.contentTintColor = ink
        icon.contentTintColor = selected ? ink : c.textSecondary
        shortcut.textColor = selected ? ink.withAlphaComponent(0.8) : c.textTertiary
    }

    /// Dark text on a light accent, white on a dark one.
    private static func ink(on fill: NSColor) -> NSColor {
        let rgb = fill.usingColorSpace(.sRGB) ?? fill
        let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        return luminance > 0.6 ? NSColor(white: 0.1, alpha: 1) : .white
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onRename?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

@MainActor
private final class SwitcherHeaderView: NSView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = HarnessDesign.Typography.sectionLabel
        label.textColor = HarnessChrome.current.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.Spacing.md),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HarnessDesign.Spacing.xs),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class SwitcherSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = HarnessChrome.current.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.Spacing.sm),
            line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.sm),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
