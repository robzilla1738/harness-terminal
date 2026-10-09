import AppKit
import HarnessCore
import HarnessTerminalKit

/// A transient, cursor-anchored path picker. The destination belongs to the pane that
/// opened it, even while a remote lookup or insertion is in flight.
@MainActor
final class DirectoryBrowserController: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private static var current: DirectoryBrowserController?
    enum Mode { case directory, insert }

    static func present(over window: NSWindow?, mode: Mode = .directory) {
        current?.close(restoreFocus: false)
        guard let surface = SessionCoordinator.shared.activeSurfaceID else { return }
        let browser = DirectoryBrowserController(surface: surface, mode: mode)
        guard let parent = browser.host?.window ?? window else { return }
        current = browser
        browser.show(over: parent)
        browser.load(path: nil)
    }

    private let surface: SurfaceID
    private let mode: Mode
    private let endpoint: Endpoint
    private let sessionID: SessionID?
    private weak var host: TerminalHostView?
    private weak var parentWindow: NSWindow?
    private let panel = KeyablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let background = HarnessOverlayBackground(opaque: true)
    private let field = NSSearchField()
    private let scope = HarnessSegmented(frame: .zero)
    private let pathLabel = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "Looking for paths…")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var pendingSearch: UUID?
    private var debounce: DispatchWorkItem?
    private var listing = PaneDirListing(root: "/", entries: [])
    private var listedRoot: String?
    private var shown: [PaneDirEntry] = []
    private var loaded = false
    private var submitting = false
    private var closed = false
    private var loading = 0
    private var anchorRect = NSRect.zero

    private init(surface: SurfaceID, mode: Mode) {
        self.surface = surface
        self.mode = mode
        let coordinator = SessionCoordinator.shared
        endpoint = coordinator.activeEndpoint
        sessionID = coordinator.snapshot.activeWorkspace?.activeSessionID
        host = coordinator.terminalHostIfExists(for: surface)
        super.init()
        panel.title = mode == .insert ? "Insert Path" : "Go to Directory"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.contentView = background

        field.placeholderString = mode == .insert ? "Find a file or folder…" : "Find a folder…"
        field.setAccessibilityLabel(mode == .insert ? "Find a file or folder" : "Find a folder")
        field.font = PathPickerStyle.body
        field.focusRingType = .none
        field.delegate = self
        field.sendsSearchStringImmediately = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(equalToConstant: 28).isActive = true

        scope.style = .tabs
        scope.setSegments(["Folder", "Project"])
        scope.selectedSegment = 0
        scope.font = PathPickerStyle.caption
        scope.setContentHuggingPriority(.required, for: .horizontal)
        scope.setContentCompressionResistancePriority(.required, for: .horizontal)
        scope.setAccessibilityLabel("Search scope")
        scope.toolTip = "Search this folder or fuzzy-find paths throughout the project"
        scope.target = self
        scope.action = #selector(scopeChanged)
        let up = NSButton(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Parent folder")!, target: self, action: #selector(goUp))
        up.isBordered = false
        up.controlSize = .small
        up.toolTip = "Parent folder (⌘↑)"
        up.widthAnchor.constraint(equalToConstant: 18).isActive = true
        pathLabel.font = PathPickerStyle.caption
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let location = NSStackView(views: [up, pathLabel, scope])
        location.spacing = 6
        location.distribution = .fill
        location.heightAnchor.constraint(equalToConstant: 26).isActive = true
        pathLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        let column = NSTableColumn(identifier: .init("path"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = PathPickerStyle.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Matching paths")
        table.allowsMultipleSelection = mode == .insert
        table.target = self
        table.action = #selector(selectionClicked)
        table.doubleAction = #selector(activateClickedRow)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: PathPickerStyle.rowHeight).isActive = true
        emptyLabel.font = PathPickerStyle.body
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        status.font = PathPickerStyle.caption
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.stringValue = mode == .insert ? "↩ Insert   → Open   Esc Close" : "↩ cd   ⌘↩ Tab   ⌥↩ Insert"
        hint.font = PathPickerStyle.caption
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [status, NSView(), hint])
        footer.spacing = 8
        footer.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let stack = NSStackView(views: [field, location, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: background.contentView.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: background.contentView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: background.contentView.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: background.contentView.bottomAnchor, constant: -10),
        ])
        for view in [field, location, scroll, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        applyTheme()
    }

    /// Screen-space placement, including displays with negative origins. Prefer below the
    /// cursor, then above it; clamp the complete popup to the visible parent window.
    static func popupFrame(anchor: NSRect, available: NSRect, visibleRows: Int = 8) -> NSRect {
        let bounds = available.insetBy(dx: 8, dy: 8)
        let rows = visibleRows == 0 ? 2 : min(8, max(1, visibleRows))
        let size = NSSize(width: min(340, bounds.width), height: min(PathPickerStyle.chromeHeight + CGFloat(rows) * PathPickerStyle.rowHeight, bounds.height))
        let belowSpace = anchor.minY - 5 - bounds.minY
        let aboveSpace = bounds.maxY - anchor.maxY - 5
        // Choose the side using the full list height, so filtering never flips it.
        let below = belowSpace >= min(PathPickerStyle.chromeHeight + 8 * PathPickerStyle.rowHeight, bounds.height) || belowSpace >= aboveSpace
        let y = below ? anchor.minY - size.height - 5 : anchor.maxY + 5
        return NSRect(x: min(max(anchor.minX - 8, bounds.minX), bounds.maxX - size.width).rounded(),
                      y: min(max(y, bounds.minY), bounds.maxY - size.height).rounded(),
                      width: size.width, height: size.height)
    }

    private func show(over window: NSWindow) {
        parentWindow = window
        anchorRect = host?.cursorRectInScreen ?? NSRect(x: window.frame.minX + 24, y: window.frame.midY, width: 1, height: 18)
        resizePopup(visibleRows: 3)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            center.addObserver(self, selector: #selector(dismiss), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(dismiss), name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(snapshotChanged(_:)), name: NotificationBus.shared.snapshotChanged, object: nil)
    }

    private func resizePopup(visibleRows: Int) {
        guard let window = parentWindow else { return }
        let screen = window.screen?.visibleFrame ?? window.frame
        let visibleWindow = window.frame.intersection(screen)
        let available = visibleWindow.width >= 320 && visibleWindow.height >= 220 ? visibleWindow : screen
        panel.setFrame(Self.popupFrame(anchor: anchorRect, available: available, visibleRows: visibleRows), display: true)
    }

    private func applyTheme() {
        let palette = HarnessDesign.chrome
        panel.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        background.applyTheme()
        scope.applyChrome()
        field.textColor = palette.textPrimary
        pathLabel.textColor = palette.textSecondary
        status.textColor = palette.textSecondary
        hint.textColor = palette.textSecondary
        emptyLabel.textColor = palette.textSecondary
        table.reloadData()
    }

    @objc private func snapshotChanged(_ notification: Notification) {
        guard host?.window === parentWindow, SessionCoordinator.shared.activeSurfaceID == surface else {
            close(restoreFocus: false)
            return
        }
        if notification.userInfo?["chromeChanged"] as? Bool == true { applyTheme() }
    }

    @objc private func dismiss() { close(restoreFocus: false) }

    private func close(restoreFocus: Bool = true) {
        guard !closed else { return }
        closed = true
        debounce?.cancel()
        cancelSearch()
        loading += 1
        NotificationCenter.default.removeObserver(self)
        parentWindow?.removeChildWindow(panel)
        panel.orderOut(nil)
        if restoreFocus, let host, host.window === parentWindow {
            parentWindow?.makeKeyAndOrderFront(nil)
            host.focusTerminal()
        }
        if Self.current === self { Self.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) { close(restoreFocus: false) }

    private func cancelSearch() {
        guard let id = pendingSearch else { return }
        let endpoint = endpoint
        DispatchQueue.global(qos: .utility).async {
            do { _ = try DaemonClient(endpoint: endpoint).request(.cancelSearch(id: id)) }
            catch { fputs("Harness path search cancellation failed: \(error)\n", harnessStderr) }
        }
        pendingSearch = nil
    }

    @objc private func scopeChanged() {
        debounce?.cancel()
        load(path: listedRoot)
        panel.makeFirstResponder(field)
    }

    private func load(path: String?) {
        guard !closed, !submitting else { return }
        debounce?.cancel()
        cancelSearch()
        loading += 1
        let ticket = loading, id = UUID()
        pendingSearch = id
        let client = DaemonClient(endpoint: endpoint)
        let surfaceID = surface.uuidString, query = field.stringValue
        let project = scope.selectedSegment == 1
        loaded = false
        status.stringValue = "Searching…"
        table.alphaValue = 0.45
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<PaneDirListing, Error> {
                let response = try client.request(.searchPaths(id: id, surfaceID: surfaceID, path: path, query: query, project: project), timeout: 10)
                if case let .error(message) = response { throw SetupError.invalid(message == "unrecognized request" ? "Update this host's daemon to use the path picker." : message) }
                guard case let .text(body) = response, let listing = PaneDirectory.decode(body) else { throw SetupError.invalid("Could not read this folder.") }
                return listing
            }
            DispatchQueue.main.async {
                guard !self.closed, ticket == self.loading else { return }
                self.pendingSearch = nil
                self.table.alphaValue = 1
                switch result {
                case let .success(listing):
                    self.loaded = true
                    self.listing = listing
                    self.listedRoot = listing.root
                    self.refresh()
                case let .failure(error):
                    self.shown = []
                    self.table.reloadData()
                    self.emptyLabel.stringValue = "Couldn’t load paths"
                    self.emptyLabel.isHidden = false
                    self.emptyLabel.setAccessibilityHidden(false)
                    self.resizePopup(visibleRows: 2)
                    self.status.stringValue = error.localizedDescription
                    self.status.toolTip = error.localizedDescription
                    self.status.setAccessibilityLabel(error.localizedDescription)
                }
            }
        }
    }

    private func refresh() {
        shown = listing.entries.filter { mode == .insert || $0.directory }
        let components = (listing.root as NSString).pathComponents.filter { $0 != "/" }.suffix(2)
        pathLabel.stringValue = components.isEmpty ? "/" : components.joined(separator: " / ")
        pathLabel.toolTip = listing.root
        emptyLabel.stringValue = shown.isEmpty ? (field.stringValue.isEmpty ? "This folder is empty" : "No matching paths") : ""
        emptyLabel.isHidden = !shown.isEmpty
        emptyLabel.setAccessibilityHidden(!shown.isEmpty)
        resizePopup(visibleRows: shown.count)
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        updateStatus()
    }

    private func updateStatus() {
        guard loaded, !submitting else { return }
        status.stringValue = table.numberOfSelectedRows > 1 ? "\(table.numberOfSelectedRows) selected" : "\(shown.count) \(shown.count == 1 ? "path" : "paths")\(listing.entries.count == 200 ? " · refine search" : "")"
        status.toolTip = nil
        status.setAccessibilityLabel(status.stringValue)
    }

    @objc private func activateClickedRow() {
        guard loaded, shown.indices.contains(table.clickedRow) else { return }
        if shown[table.clickedRow].directory { openSelected() } else { finish([]) }
    }

    @objc private func selectionClicked() { panel.makeFirstResponder(field) }

    private func openSelected() {
        guard loaded, !submitting, shown.indices.contains(table.selectedRow), shown[table.selectedRow].directory else { return }
        field.stringValue = ""
        scope.selectedSegment = 0
        load(path: shown[table.selectedRow].path)
    }

    @objc private func goUp() {
        guard let listedRoot, !submitting else { return }
        field.stringValue = ""
        scope.selectedSegment = 0
        let parent = (listedRoot as NSString).deletingLastPathComponent
        load(path: parent.isEmpty ? "/" : parent)
    }

    private func finish(_ modifiers: NSEvent.ModifierFlags) {
        guard loaded, !submitting else { return }
        let selected = table.selectedRowIndexes.filter { shown.indices.contains($0) }.map { shown[$0].path }
        // An unmatched query must never insert or cd to the root by accident.
        guard !selected.isEmpty || field.stringValue.isEmpty else { return }
        let paths = selected.isEmpty ? [listing.root] : selected
        guard paths.allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            status.stringValue = "This path contains unsupported control characters."
            status.toolTip = status.stringValue
            return
        }
        let request: IPCRequest
        if mode == .insert || modifiers.contains(.option) {
            request = .send(surfaceID: surface.uuidString, text: PaneDirectory.insertion(paths))
        } else if modifiers.contains(.command), let sessionID {
            request = .newTabInSession(sessionID: sessionID, cwd: paths[0])
        } else {
            request = .send(surfaceID: surface.uuidString, text: PaneDirectory.goToDirectory(paths[0]) + "\r")
        }
        let endpoint = endpoint
        submitting = true
        field.isEnabled = false
        scope.isEnabled = false
        status.stringValue = "Inserting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result<IPCResponse, Error> { try DaemonClient(endpoint: endpoint).request(request) }
            DispatchQueue.main.async {
                guard !self.closed else { return }
                self.submitting = false
                self.field.isEnabled = true
                self.scope.isEnabled = true
                switch result {
                case let .success(.error(message)): self.status.stringValue = message
                case .success: self.close(); SessionCoordinator.shared.refreshSnapshot()
                case let .failure(error): self.status.stringValue = error.localizedDescription
                }
                self.status.toolTip = self.status.stringValue
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !submitting else { return }
        debounce?.cancel()
        cancelSearch()
        loading += 1
        loaded = false
        status.stringValue = "Searching…"
        table.alphaValue = 0.45
        let path = listedRoot
        let work = DispatchWorkItem { [weak self] in self?.load(path: path) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Let the input method commit its marked text before interpreting navigation.
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): step(-1)
        case #selector(NSResponder.moveDown(_:)): step(1)
        case #selector(NSResponder.moveToBeginningOfDocument(_:)): goUp()
        case #selector(NSResponder.moveRight(_:)) where textView.selectedRange().location == (field.stringValue as NSString).length:
            openSelected()
        case #selector(NSResponder.insertTab(_:)):
            guard loaded, shown.indices.contains(table.selectedRow), shown[table.selectedRow].directory else { return false }
            openSelected()
        case #selector(NSResponder.moveLeft(_:)) where field.stringValue.isEmpty: goUp()
        case #selector(NSResponder.insertNewline(_:)): finish(NSApp.currentEvent?.modifierFlags ?? [])
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func step(_ delta: Int) {
        guard loaded, !shown.isEmpty else { return }
        let next = max(0, min(shown.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateStatus() }
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PathPickerRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("path")
        let cell = table.makeView(withIdentifier: identifier, owner: self) as? PathPickerCellView ?? PathPickerCellView()
        cell.identifier = identifier
        cell.configure(shown[row])
        return cell
    }
}

@MainActor
private final class PathPickerRowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let palette = HarnessDesign.chrome
        let fill = palette.sidebarBackground.blended(withFraction: palette.isDark ? 0.28 : 0.18, of: palette.accent) ?? palette.activePillFill
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

@MainActor
private final class PathPickerCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = PathPickerStyle.body
        label.maximumNumberOfLines = 1
        label.cell?.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingHead
        addSubview(icon)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: PaneDirEntry) {
        let ext = (entry.name as NSString).pathExtension.lowercased()
        let symbol: String
        if entry.directory { symbol = "folder.fill" }
        else if ["png", "jpg", "jpeg", "svg", "gif", "webp"].contains(ext) { symbol = "photo" }
        else if ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "sh", "json"].contains(ext) { symbol = "chevron.left.forwardslash.chevron.right" }
        else { symbol = "doc.text" }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: entry.directory ? "Folder" : "File")
        icon.contentTintColor = entry.directory ? .systemTeal : HarnessDesign.chrome.textSecondary
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingHead
        let text = NSMutableAttributedString(string: entry.name, attributes: [.font: PathPickerStyle.body, .foregroundColor: HarnessDesign.chrome.textSecondary, .paragraphStyle: paragraph])
        let filename = (entry.name as NSString).lastPathComponent
        let range = (entry.name as NSString).range(of: filename, options: .backwards)
        text.addAttribute(.foregroundColor, value: HarnessDesign.chrome.textPrimary, range: range)
        label.attributedStringValue = text
        toolTip = entry.path
        setAccessibilityLabel(entry.name + (entry.directory ? ", folder" : ", file"))
    }
}

@MainActor
private enum PathPickerStyle {
    static let body = NSFont.systemFont(ofSize: 13)
    static let caption = NSFont.systemFont(ofSize: 11)
    static let rowHeight: CGFloat = 26
    static let chromeHeight: CGFloat = 112
}
