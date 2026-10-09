import AppKit
import HarnessCore

@MainActor
final class SetupEditorController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var setup: SavedSetup
    private var panes: [(tab: Int, pane: SetupPane)]
    private let nameField = NSTextField()
    private let table = NSTableView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton()
    private let cancelButton = NSButton()
    private var isSaving = false
    private let onSave: (SavedSetup, @escaping (String?) -> Void) -> Void

    init(setup: SavedSetup, onSave: @escaping (SavedSetup, @escaping (String?) -> Void) -> Void) {
        self.setup = setup
        panes = setup.tabs.enumerated().flatMap { index, tab in tab.layout.panes.map { (index, $0) } }
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Edit Saved Setup"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 800, height: 460)
        super.init(window: window)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .width
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        nameField.stringValue = setup.name
        nameField.placeholderString = "Setup name"
        nameField.setAccessibilityLabel("Setup name")
        root.addArrangedSubview(nameField)
        let explanation = NSTextField(wrappingLabelWithString: "Each row is a pane. Startup commands are optional and run only when creating a new session. Opening a running setup returns to it. Use Update from Current to save a different split layout.")
        explanation.textColor = .secondaryLabelColor
        root.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        for (id, title, width) in [("tab", "Tab", 140.0), ("directory", "Directory on host", 250.0), ("shell", "Shell", 150.0), ("command", "Startup command (optional)", 230.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.isEditable = true
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        root.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        errorLabel.textColor = .systemRed
        root.addArrangedSubview(errorLabel)
        cancelButton.title = "Cancel"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        saveButton.title = "Save Setup"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        root.addArrangedSubview(NSStackView(views: [cancelButton, saveButton]))
        window.contentView?.addSubview(root)
        if let content = window.contentView {
            NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func numberOfRows(in tableView: NSTableView) -> Int { panes.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        switch tableColumn?.identifier.rawValue {
        case "tab": setup.tabs[panes[row].tab].title
        case "directory": panes[row].pane.directory
        case "shell": panes[row].pane.shell ?? ""
        case "command": panes[row].pane.startupCommand ?? ""
        default: nil
        }
    }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard let value = object as? String else { return }
        switch tableColumn?.identifier.rawValue {
        case "tab": setup.tabs[panes[row].tab].title = value
        case "directory": panes[row].pane.directory = value
        case "shell": panes[row].pane.shell = value.isEmpty ? nil : value
        case "command": panes[row].pane.startupCommand = value.isEmpty ? nil : value
        default: return
        }
        table.reloadData()
    }

    @objc private func cancel() {
        guard !isSaving else { return }
        if let window { window.sheetParent?.endSheet(window) }
        close()
    }
    @objc private func save() {
        guard !isSaving, window?.makeFirstResponder(nil) == true else { return }
        setup.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = 0
        func replacing(_ layout: SetupLayout) -> SetupLayout {
            switch layout {
            case .pane:
                defer { index += 1 }
                return .pane(panes[index].pane)
            case let .split(direction, ratio, first, second):
                return .split(direction: direction, ratio: ratio, first: replacing(first), second: replacing(second))
            }
        }
        for tab in setup.tabs.indices { setup.tabs[tab].layout = replacing(setup.tabs[tab].layout) }
        do { try setup.validate() } catch { errorLabel.stringValue = error.localizedDescription; return }
        isSaving = true
        saveButton.isEnabled = false
        saveButton.title = "Saving…"
        cancelButton.isEnabled = false
        errorLabel.stringValue = ""
        onSave(setup) { [weak self] error in
            guard let self else { return }
            isSaving = false
            saveButton.isEnabled = true
            saveButton.title = "Save Setup"
            cancelButton.isEnabled = true
            if let error { errorLabel.stringValue = error } else { cancel() }
        }
    }
}
