import AppKit
import HarnessCore
import UniformTypeIdentifiers

@MainActor
final class SessionLibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SessionLibraryController()
    private let hosts = NSPopUpButton()
    private let section = NSSegmentedControl(labels: ["Saved Setups", "Recently Closed"], trackingMode: .selectOne, target: nil, action: nil)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var actionButtons: [String: NSButton] = [:]
    private var owners: [String] = []
    private var library = SessionLibrary()
    private var editor: SetupEditorController?
    private var generation = 0
    private var isBusy = false
    private var hostOwner: String { owners.indices.contains(hosts.indexOfSelectedItem) ? owners[hosts.indexOfSelectedItem] : SessionCoordinator.shared.activeOwner }
    private var selectedSetup: SavedSetup? {
        guard section.selectedSegment == 0, library.setups.indices.contains(table.selectedRow) else { return nil }
        return library.setups[table.selectedRow]
    }
    private var selectedClosed: ClosedLayout? {
        guard section.selectedSegment == 1, library.recentlyClosed.indices.contains(table.selectedRow) else { return nil }
        return library.recentlyClosed[table.selectedRow]
    }

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 480), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Session Library"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 820, height: 440)
        super.init(window: window)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        hosts.target = self; hosts.action = #selector(reload)
        section.selectedSegment = 0; section.target = self; section.action = #selector(changeSection)
        root.addArrangedSubview(NSStackView(views: [hosts, section]))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        column.width = 600
        table.addTableColumn(column)
        table.dataSource = self; table.delegate = self
        table.rowHeight = 48
        table.target = self; table.doubleAction = #selector(open)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        for actions: [(String, Selector)] in [
            [("Open", #selector(open)), ("Open New Copy", #selector(newCopy)), ("Save Current Session", #selector(capture)), ("Edit", #selector(edit)), ("Update from Current", #selector(updateFromCurrent))],
            [("Duplicate", #selector(duplicate)), ("Delete", #selector(delete)), ("Import…", #selector(importSetup)), ("Export…", #selector(exportSetup)), ("Clear Recently Closed", #selector(clearClosed))],
        ] {
            root.addArrangedSubview(NSStackView(views: actions.map {
                let button = NSButton(title: $0.0, target: self, action: $0.1)
                actionButtons[$0.0] = button
                return button
            }))
        }
        status.textColor = .secondaryLabelColor
        root.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        window.contentView?.addSubview(root)
        if let content = window.contentView {
            NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
        window.center()
        NotificationCenter.default.addObserver(self, selector: #selector(snapshotChanged), name: NotificationBus.shared.snapshotChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present(recentlyClosed: Bool = false) {
        owners = SessionCoordinator.shared.connectedOwners
        hosts.removeAllItems()
        hosts.addItems(withTitles: owners.map { $0 == DaemonSidebar.localID ? "This Mac" : $0 })
        if let index = owners.firstIndex(of: SessionCoordinator.shared.activeOwner) { hosts.selectItem(at: index) }
        window?.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        section.selectedSegment = recentlyClosed ? 1 : 0
        showWindow(nil)
        reload()
    }

    @objc private func changeSection() { table.reloadData(); explain() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
    private func updateButtons() {
        for button in actionButtons.values { button.isEnabled = !isBusy }
        guard !isBusy else { return }
        for title in ["Edit", "Duplicate", "Export…", "Open New Copy", "Update from Current"] { actionButtons[title]?.isEnabled = selectedSetup != nil }
        for title in ["Open", "Delete"] { actionButtons[title]?.isEnabled = selectedSetup != nil || selectedClosed != nil }
        actionButtons["Clear Recently Closed"]?.isEnabled = section.selectedSegment == 1 && !library.recentlyClosed.isEmpty
    }
    @objc private func snapshotChanged() {
        guard window?.isVisible == true else { return }
        let fresh = SessionCoordinator.shared.snapshot(for: hostOwner).library
        guard library != fresh else { return }
        let setupID = selectedSetup?.id, closedID = selectedClosed?.id
        library = fresh
        table.reloadData()
        if let index = section.selectedSegment == 0 ? library.setups.firstIndex(where: { $0.id == setupID }) : library.recentlyClosed.firstIndex(where: { $0.id == closedID }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
        updateButtons()
    }
    private func explain() {
        updateButtons()
        status.stringValue = section.selectedSegment == 0 && library.setups.isEmpty ? "No saved setups yet. Save Current Session to begin." : section.selectedSegment == 0
            ? "Open returns to a running setup. Open New Copy creates another session."
            : "Recreates the layout with fresh shells. Closed processes and conversations are not resumed."
    }
    @objc private func reload() {
        isBusy = true
        updateButtons()
        generation += 1
        let token = generation
        library = SessionLibrary(); table.reloadData()
        status.stringValue = "Loading…"
        SessionCoordinator.shared.performLibrary(.list, owner: hostOwner) { [weak self] result in
            guard let self, generation == token else { return }
            isBusy = false
            defer { updateButtons() }
            do {
                guard case let .text(json) = try result.get() else { throw SetupError.invalid("The daemon did not return the session library.") }
                library = try JSONDecoder().decode(SessionLibrary.self, from: Data(json.utf8))
                table.reloadData(); explain()
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { section.selectedSegment == 0 ? library.setups.count : library.recentlyClosed.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let title: String
        let subtitle: String
        if section.selectedSegment == 0 {
            let setup = library.setups[row]
            title = setup.name
            let panes = setup.tabs.flatMap { $0.layout.panes }.count
            subtitle = "\(setup.tabs.count) \(setup.tabs.count == 1 ? "tab" : "tabs") · \(panes) \(panes == 1 ? "pane" : "panes")"
        } else {
            let closed = library.recentlyClosed[row]
            title = closed.setup.name
            subtitle = "\(closed.kind.rawValue.capitalized) · \(closed.closedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        let label = NSTextField(labelWithString: title + "\n" + subtitle)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private func perform(_ operation: LibraryOperation) {
        guard !isBusy else { return }
        isBusy = true
        updateButtons()
        let target = hostOwner
        status.stringValue = "Working…"
        SessionCoordinator.shared.performLibrary(operation, owner: target) { [weak self] result in
            guard let self else { return }
            isBusy = false
            defer { updateButtons() }
            do {
                if case let .sessionID(id) = try result.get() {
                    SessionCoordinator.shared.showDaemon(target, session: id)
                    SessionCoordinator.shared.refreshSnapshot()
                    window?.orderOut(nil)
                }
                reload()
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func open() {
        if let setup = selectedSetup { perform(.open(setup.id, mode: .existing)) }
        else if let closed = selectedClosed { perform(.restoreClosed(closed.id)) }
        else { status.stringValue = "Select an entry first." }
    }
    @objc private func newCopy() {
        guard let setup = selectedSetup else { status.stringValue = "Select a saved setup first."; return }
        perform(.open(setup.id, mode: .newCopy))
    }
    @objc private func capture() {
        let coordinator = SessionCoordinator.shared
        guard let session = coordinator.snapshot(for: hostOwner).activeWorkspace?.activeSession else { return }
        let setup = SavedSetup(name: session.name.isEmpty ? "My Setup" : session.name, tabs: session.tabs.map(SetupTab.init))
        showEditor(setup, sourceSessionID: session.id)
    }
    @objc private func updateFromCurrent() {
        guard let setup = selectedSetup,
              let session = SessionCoordinator.shared.snapshot(for: hostOwner).activeWorkspace?.activeSession else { return }
        var updated = SavedSetup(name: setup.name, tabs: session.tabs.map(SetupTab.init))
        updated.id = setup.id
        showEditor(updated, sourceSessionID: session.id)
    }
    @objc private func edit() { if let setup = selectedSetup { showEditor(setup) } }
    @objc private func duplicate() {
        guard var setup = selectedSetup else { return }
        setup.id = UUID(); setup.name += " Copy"
        showEditor(setup)
    }
    private func showEditor(_ setup: SavedSetup, sourceSessionID: SessionID? = nil) {
        let target = hostOwner
        editor = SetupEditorController(setup: setup) { [weak self] setup, completion in
            SessionCoordinator.shared.performLibrary(.save(setup, sourceSessionID: sourceSessionID), owner: target) { result in
                switch result {
                case .success: completion(nil); self?.reload()
                case let .failure(error): completion(error.localizedDescription)
                }
            }
        }
        if let window, let sheet = editor?.window { window.beginSheet(sheet) }
    }
    @objc private func delete() {
        if let setup = selectedSetup { perform(.deleteSetup(setup.id)) }
        else if let closed = selectedClosed { perform(.deleteClosed(closed.id)) }
    }
    @objc private func clearClosed() { perform(.deleteClosed(nil)) }
    @objc private func importSetup() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                var setup = try JSONDecoder().decode(SavedSetup.self, from: Data(contentsOf: url))
                try setup.validate()
                setup.id = UUID()
                showEditor(setup)
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func exportSetup() {
        guard let setup = selectedSetup, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = setup.name + ".json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(setup).write(to: url, options: .atomic)
            } catch { self?.status.stringValue = error.localizedDescription }
        }
    }
}
