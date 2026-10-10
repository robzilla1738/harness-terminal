import AppKit
import UniformTypeIdentifiers
import HarnessCore

@MainActor
final class RecordingReviewWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource {
    private let endpoint: Endpoint, surfaceID: SurfaceID?, hostOwner: String
    private let table = NSTableView(), preview = NSTextView(), status = NSTextField(wrappingLabelWithString: "Open a recording, or start a passive recording of the selected terminal.")
    private let literals = HarnessSecureTextField(), startButton = HarnessToolPage.button("Start recording…", target: nil, action: nil), stopButton = HarnessToolPage.button("Stop", target: nil, action: nil), saveButton = HarnessToolPage.button("Save reviewed .cast…", target: nil, action: nil)
    private let shareButton = HarnessToolPage.button("Share saved .cast…", target: nil, action: nil)
    private var savedExportURL: URL?
    private let workers = OperationQueue(), captureWorkers = OperationQueue()
    private var cancellation = UIWorkCancellation()
    private var recorder: LiveTerminalRecorder?, sourceURL: URL?, review: RecordingExportReview?, rendered: Data?
    private var mask: Set<Int> = [], additions: [String] = [], generation = 0, closed = false
    var onClose: (() -> Void)?
    init(endpoint: Endpoint, surfaceID: SurfaceID?, owner: String) {
        self.endpoint = endpoint; self.surfaceID = surfaceID; self.hostOwner = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 930, height: 730), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Recordings and reviewed export"; window.delegate = self; window.minSize = NSSize(width: 730, height: 600)
        workers.maxConcurrentOperationCount = 1; workers.qualityOfService = .utility
        captureWorkers.maxConcurrentOperationCount = 1; captureWorkers.qualityOfService = .utility
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        let open = HarnessToolPage.button("Open recording…", target: self, action: #selector(openRecording)), protect = HarnessToolPage.button("Protect legacy file", target: self, action: #selector(protectRecording))
        startButton.target = self; startButton.action = #selector(startRecording); startButton.isEnabled = surfaceID != nil
        stopButton.target = self; stopButton.action = #selector(stopRecording); stopButton.isEnabled = false
        saveButton.target = self; saveButton.action = #selector(saveExport); saveButton.isEnabled = false
        let toggle = HarnessToolPage.button("Toggle selected mask", target: self, action: #selector(toggleMask))
        let controls = HarnessToolPage.actionRows([open, startButton, stopButton, protect]); root.addArrangedSubview(controls)
        shareButton.target = self; shareButton.action = #selector(shareSavedExport); shareButton.isEnabled = false
        let exportControls = NSStackView(views: [saveButton, shareButton]); exportControls.spacing = 8
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: "The .cast is plaintext. Input and unsafe controls are omitted. Masking is heuristic: review all output and add literal redactions before sharing."))
        for (id, title, width) in [("mask", "Mask", 48.0), ("reason", "Candidate", 175.0), ("time", "Seconds", 65.0), ("context", "Context (candidate masked)", 540.0)] { let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            if id == "mask" { let cell = NSButtonCell(); cell.setButtonType(.switch); cell.title = ""; column.dataCell = cell; column.isEditable = true }
            table.addTableColumn(column) }
        table.dataSource = self; table.rowHeight = 28; table.setAccessibilityLabel("Reviewed secret candidates")
        let list = NSScrollView(); list.hasVerticalScroller = true; list.hasHorizontalScroller = true; list.documentView = table; list.heightAnchor.constraint(equalToConstant: 170).isActive = true; root.addArrangedSubview(list)
        literals.placeholderString = "Literal text to mask (kept only in memory)"; literals.setAccessibilityLabel("Additional literal redaction")
        let add = HarnessToolPage.button("Add literal", target: self, action: #selector(addLiteral)), clear = HarnessToolPage.button("Clear added literals", target: self, action: #selector(clearLiterals))
        let editing = NSStackView(views: [HarnessToolPage.field("Additional literal redaction", control: literals), HarnessToolPage.actionRows([add, clear, toggle])]); editing.orientation = .vertical; editing.alignment = .leading; editing.spacing = 8; editing.arrangedSubviews[0].widthAnchor.constraint(equalTo: editing.widthAnchor).isActive = true; root.addArrangedSubview(editing)
        preview.isEditable = false; preview.isSelectable = true; preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular); preview.setAccessibilityLabel("Complete reviewed asciicast content, with control characters escaped")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = preview; preview.isVerticallyResizable = true; preview.autoresizingMask = [.width]; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true; root.addArrangedSubview(scroll)
        root.addArrangedSubview(exportControls); root.addArrangedSubview(status)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }
        window.contentView = root; HarnessToolPage.group(root, title: "Secret candidates", views: [list, editing]); HarnessToolPage.group(root, title: "Reviewed export", views: [scroll, exportControls]); HarnessToolPage.install(in: window, title: "Recordings", subtitle: "Capture, review, redact, and share terminal output.", symbol: "record.circle", content: root); window.center()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; generation += 1; cancellation.cancel(); workers.cancelAllOperations(); captureWorkers.cancelAllOperations(); let recorder = recorder; self.recorder = nil; captureWorkers.addOperation { recorder?.stop() }; additions.removeAll(); literals.stringValue = ""; onClose?() }
    func numberOfRows(in tableView: NSTableView) -> Int { review?.candidates.count ?? 0 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard let candidate = review?.candidates[row] else { return nil }
        switch tableColumn?.identifier.rawValue { case "mask": return NSNumber(value: mask.contains(candidate.id)); case "reason": return candidate.reason; case "time": return String(format: "%.3f", Double(candidate.timeMs) / 1000); default: return candidate.context.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    }
    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        guard tableColumn?.identifier.rawValue == "mask", let review, review.candidates.indices.contains(row) else { return }
        let id = review.candidates[row].id
        if (object as? NSNumber)?.boolValue == true { mask.insert(id) } else { mask.remove(id) }; render()
    }
    override func windowDidLoad() { super.windowDidLoad() }
    @objc private func openRecording() { let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; guard panel.runModal() == .OK, let url = panel.url else { return }; load(url) }
    private func load(_ url: URL) {
        generation += 1; let generation = generation; cancellation.cancel(); cancellation = UIWorkCancellation(); let cancellation = cancellation; workers.cancelAllOperations(); rendered = nil; saveButton.isEnabled = false; status.stringValue = "Reading and reviewing recording…"
        review = nil; sourceURL = nil; mask.removeAll(); additions.removeAll(); literals.stringValue = ""
        savedExportURL = nil; shareButton.isEnabled = false; preview.string = ""; table.reloadData()
        workers.addOperation { [weak self] in
            let result = Result { try AsciicastExport.review(RecordingArchive.read(url), cancelled: { cancellation.isCancelled }) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == generation else { return }
                switch result {
                case let .success(value): self.sourceURL = url; self.review = value; self.mask = Set(value.candidates.map(\.id)); self.additions.removeAll(); self.table.reloadData(); self.table.target = self; self.table.doubleAction = #selector(self.toggleMask); self.render()
                case let .failure(error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func toggleMask() { guard let review, review.candidates.indices.contains(table.selectedRow) else { return }; let id = review.candidates[table.selectedRow].id; if mask.contains(id) { mask.remove(id) } else { mask.insert(id) }; table.reloadData(); render() }
    @objc private func addLiteral() { guard !literals.stringValue.isEmpty, additions.count < 64 else { return }; additions.append(literals.stringValue); literals.stringValue = ""; render() }
    @objc private func clearLiterals() { additions.removeAll(); render() }
    private func render() {
        guard let review else { return }; generation += 1; let generation = generation, mask = mask, additions = additions
        rendered = nil; saveButton.isEnabled = false; cancellation.cancel(); cancellation = UIWorkCancellation(); let cancellation = cancellation; workers.cancelAllOperations()
        savedExportURL = nil; shareButton.isEnabled = false
        workers.addOperation { [weak self] in
            let result = Result { try AsciicastExport.render(review, masking: mask, additionalLiterals: additions, cancelled: { cancellation.isCancelled }) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == generation else { return }
                switch result {
                case let .success(data): self.rendered = data; self.preview.string = String(decoding: data, as: UTF8.self); self.saveButton.isEnabled = true; self.status.stringValue = "Source: " + review.protection + "\n" + review.warnings.joined(separator: "\n") + "\n\(mask.count) candidate masks · \(additions.count) literal additions · double-click a candidate to toggle its mask."
                case let .failure(error): self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    @objc private func startRecording() {
        guard recorder == nil, let surfaceID else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "Harness-recording.hrec"; panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Recording never truncates an existing file, even if Save Panel offered replacement.
        let recorder = LiveTerminalRecorder(client: DaemonClient(endpoint: endpoint), surfaceID: surfaceID.uuidString, url: url, onUpdate: { [weak self] value in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }
                self.status.stringValue = value.failure ?? (value.phase == .recording ? "Recording on \(self.hostOwner). Stop to finish and review the capture." : "\(value.phase.rawValue.capitalized) on \(self.hostOwner) · \(value.events) events · \(Double(value.durationMs) / 1000)s")
                if value.complete { self.recorder = nil; self.stopButton.isEnabled = false; self.startButton.isEnabled = true; if value.failure == nil { self.load(url) } }
            }
        })
        self.recorder = recorder; startButton.isEnabled = false; stopButton.isEnabled = true; captureWorkers.addOperation { recorder.start() }
    }
    @objc private func stopRecording() { let recorder = recorder; captureWorkers.addOperation { recorder?.stop() } }
    @objc private func protectRecording() {
        guard let sourceURL else { return }; let generation = generation
        workers.addOperation { [weak self] in
            let result = Result { try RecordingArchive.protectLegacy(at: sourceURL) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == generation else { return }
                switch result { case .success: self.load(sourceURL); case let .failure(error): self.status.stringValue = error.localizedDescription }
            }
        }
    }
    @objc private func shareSavedExport() {
        guard let savedExportURL else { return }
        NSSharingServicePicker(items: [savedExportURL]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }
    @objc private func saveExport() {
        guard let rendered else { return }; let generation = generation
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Harness-reviewed.cast"; panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url, !closed, self.generation == generation else { return }
        workers.addOperation { [weak self] in
            let result = Result { let prior = try PrivateFile.read(url, maximumBytes: 32 << 20); try AsciicastExport.save(rendered, to: url, replacing: prior) }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == generation else { return }
                switch result { case .success: self.savedExportURL = url; self.shareButton.isEnabled = true; self.status.stringValue = "Saved reviewed plaintext .cast. The Share button uses this saved file."; case let .failure(error): self.status.stringValue = error.localizedDescription }
            }
        }
    }
}
