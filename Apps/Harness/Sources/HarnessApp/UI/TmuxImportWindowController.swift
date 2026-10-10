import AppKit
import HarnessCore

@MainActor
final class TmuxImportWindowController: NSWindowController, NSWindowDelegate {
    private let hostOwner: String, localCapture: Bool
    private let choices = HarnessSelect(), preview = NSTextView(), status = NSTextField(wrappingLabelWithString: "Read a tmux server or open a snapshot JSON file. Preview creates no PTYs and changes no settings.")
    private let save = HarnessToolPage.button("Save selected setup", target: nil, action: nil)
    private var proposals: [TmuxSetupProposal] = [], closed = false, generation = 0
    private let workers = OperationQueue()
    private var cancellation = UIWorkCancellation()
    var onClose: (() -> Void)?
    init(owner: String, localCapture: Bool) {
        self.hostOwner = owner; self.localCapture = localCapture
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Import tmux layout into " + owner; window.delegate = self; window.minSize = NSSize(width: 620, height: 480)
        workers.maxConcurrentOperationCount = 1; workers.qualityOfService = .utility
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16)
        let capture = HarnessToolPage.button("Read local tmux…", target: self, action: #selector(captureLocal)); capture.isEnabled = localCapture
        let open = HarnessToolPage.button("Open snapshot…", target: self, action: #selector(openSnapshot)); save.target = self; save.action = #selector(saveSelected); save.isEnabled = false
        let row = NSStackView(views: [capture, open, save]); row.spacing = 8; root.addArrangedSubview(row)
        choices.emptyTitle = "Load a layout to preview"; choices.target = self; choices.action = #selector(selectProposal); choices.setAccessibilityLabel("tmux session proposal"); root.addArrangedSubview(choices)
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: "Startup commands below are unchecked suggestions only. Save creates a Saved Setup; it does not attach tmux PTYs or open Harness shells. Snapshot directories must exist on " + hostOwner + " when the setup is opened."))
        preview.isEditable = false; preview.isSelectable = true; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular); preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; preview.setAccessibilityLabel("Layout, directories, unchecked startup suggestions and warnings")
        let scroll = NSScrollView(); scroll.documentView = preview; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true; root.addArrangedSubview(scroll); root.addArrangedSubview(status)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        window.contentView = root; HarnessToolPage.group(root, title: "Layout preview", views: [choices, scroll]); HarnessToolPage.install(in: window, title: "Import tmux", subtitle: "Review your layout before saving it as a reusable setup.", symbol: "rectangle.split.2x2", content: root); window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; cancellation.cancel(); workers.cancelAllOperations(); onClose?() }
    private func load(_ operation: @escaping @Sendable (UIWorkCancellation) throws -> TmuxImportSnapshot) {
        generation += 1; let generation = generation; cancellation.cancel(); cancellation = UIWorkCancellation(); let cancellation = cancellation; workers.cancelAllOperations(); save.isEnabled = false; status.stringValue = "Reading bounded tmux snapshot…"
        workers.addOperation { [weak self] in
            let result = Result { try TmuxLayoutImport.proposals(operation(cancellation)) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == generation else { return }
                switch result {
                case let .success(values): self.proposals = values; self.choices.removeAllItems(); self.choices.addItems(withTitles: values.map { $0.sourceSessionID + " · " + $0.setup.name }); self.selectProposal()
                case let .failure(error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func captureLocal() {
        guard localCapture else { return }
        let alert = NSAlert(); alert.messageText = "Read tmux server"; alert.informativeText = "Optional absolute server socket path. Leave blank for your default server. Only list and display commands are issued."
        let field = HarnessTextField(string: ""); field.frame = NSRect(x: 0, y: 0, width: 450, height: HarnessDesign.formControlHeight); field.setAccessibilityLabel("Optional tmux socket path"); field.placeholderString = "/absolute/path/to/tmux.sock (optional)"; alert.accessoryView = field; alert.addButton(withTitle: "Preview"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }; let socket = field.stringValue.isEmpty ? nil : field.stringValue
        load { cancellation in try TmuxSnapshotCapture.capture(executable: TmuxSnapshotCapture.executable(), socketPath: socket, cancelled: { cancellation.isCancelled }) }
    }
    @objc private func openSnapshot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; guard panel.runModal() == .OK, let url = panel.url else { return }
        load { cancellation in guard !cancellation.isCancelled, let data = try PrivateFile.read(url) else { throw TmuxImportError.unavailable }; return try JSONDecoder().decode(TmuxImportSnapshot.self, from: data) }
    }
    @objc private func selectProposal() {
        guard proposals.indices.contains(choices.indexOfSelectedItem) else { return }; let proposal = proposals[choices.indexOfSelectedItem]
        var lines = [proposal.setup.name, "Session " + proposal.sourceSessionID, ""]
        for (index, tab) in proposal.setup.tabs.enumerated() {
            let source = proposal.sourceWindowIDs.indices.contains(index) ? " · " + proposal.sourceWindowIDs[index] : ""
            lines.append("Window \(index + 1): " + tab.title + source)
            appendLayout(tab.layout, indent: "  ", to: &lines)
            lines.append("")
        }
        let suggestions = proposal.suggestions.filter { !($0.startupSuggestion ?? "").isEmpty }
        if !suggestions.isEmpty {
            lines.append("Startup suggestions — not selected or executed")
            for pane in suggestions {
                lines.append("  " + pane.id + " · " + pane.directory)
                lines.append("    " + (pane.startupSuggestion ?? ""))
            }
            lines.append("")
        }
        if !proposal.warnings.isEmpty { lines.append("Notes"); lines.append(contentsOf: proposal.warnings.map { "• " + $0 }) }
        preview.string = lines.joined(separator: "\n")
        preview.scrollToBeginningOfDocument(nil)
        save.isEnabled = true
        status.stringValue = "Review " + proposal.setup.name + " before saving to " + hostOwner + ". Suggestions remain unchecked and are not copied into startup commands."
    }
    private func appendLayout(_ layout: SetupLayout, indent: String, to lines: inout [String]) {
        switch layout {
        case let .pane(pane): lines.append(indent + "Terminal · " + pane.directory)
        case let .split(direction, ratio, first, second):
            let percentage = Int((ratio * 100).rounded())
            lines.append(indent + (direction == .horizontal ? "Side by side" : "Top and bottom") + " · \(percentage)% / \(100 - percentage)%")
            appendLayout(first, indent: indent + "  ", to: &lines)
            appendLayout(second, indent: indent + "  ", to: &lines)
        }
    }
    @objc private func saveSelected() {
        guard proposals.indices.contains(choices.indexOfSelectedItem) else { return }; let proposal = proposals[choices.indexOfSelectedItem]; save.isEnabled = false
        SessionCoordinator.shared.performLibrary(.save(proposal.setup), owner: hostOwner) { [weak self] result in
            guard let self, !self.closed else { return }
            switch result { case .success: self.status.stringValue = "Saved " + proposal.setup.name + ". Open it from Saved Setups when ready; tmux programs were left untouched."
            case let .failure(error): self.save.isEnabled = true; self.status.stringValue = error.localizedDescription }
        }
    }
}
