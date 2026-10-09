import AppKit
import HarnessCore

@MainActor
final class OutputSearchController: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = OutputSearchController()
    private let queryField = NSSearchField()
    private let scope = NSPopUpButton()
    private let matchCase = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let table = NSTableView()
    private let status = NSTextField(wrappingLabelWithString: "Search retained output in open sessions. Closed output is not archived.")
    private let openButton = NSButton(title: "Open Pane", target: nil, action: nil)
    private let moreButton = NSButton(title: "Load More", target: nil, action: nil)
    private var results: [(owner: String, match: OutputSearchMatch, epoch: String, revision: Int)] = []
    private var pending: [(id: UUID, endpoint: Endpoint)] = []
    private var nextOffsets: [String: Int] = [:]
    private var searchGenerations: [String: String] = [:]
    private var errors: [String] = []
    private var generation = 0
    private var remaining = 0
    private var debounce: DispatchWorkItem?
    private var sourceOwner = ""
    private var sourceSession: SessionID?
    private var searchedQuery = ""
    private var searchedCase = false
    private var openingResult = false

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Search All Sessions"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 520)
        super.init(window: window)
        window.delegate = self
        queryField.placeholderString = "Search terminal output"
        queryField.delegate = self
        scope.addItems(withTitles: ["All Hosts", "This Host", "This Session"])
        scope.target = self; scope.action = #selector(searchChanged)
        matchCase.target = self; matchCase.action = #selector(searchChanged)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.width = 660
        column.resizingMask = .autoresizingMask
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Matching output")
        table.addTableColumn(column); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 54
        table.target = self; table.doubleAction = #selector(openResult)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.documentView = table
        scroll.borderType = .bezelBorder
        moreButton.target = self; moreButton.action = #selector(loadMore); moreButton.isEnabled = false
        openButton.target = self; openButton.action = #selector(openResult); openButton.isEnabled = false
        let root = NSStackView(views: [queryField, NSStackView(views: [scope, matchCase]), scroll, status, NSStackView(views: [moreButton, openButton])])
        root.orientation = .vertical; root.alignment = .width; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -36).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        window.contentView?.addSubview(root)
        if let content = window.contentView {
            NSLayoutConstraint.activate([root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor), root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor)])
        }
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        window?.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
        sourceOwner = SessionCoordinator.shared.activeOwner
        sourceSession = SessionCoordinator.shared.snapshot.activeWorkspace?.activeSessionID
        showWindow(nil); window?.makeFirstResponder(queryField)
        searchChanged()
    }
    func windowWillClose(_ notification: Notification) { cancel() }
    private func cancel() {
        generation += 1; debounce?.cancel(); debounce = nil
        openingResult = false
        openButton.isEnabled = false
        for search in pending {
            DispatchQueue.global(qos: .utility).async {
                do { _ = try DaemonClient(endpoint: search.endpoint).request(.cancelSearch(id: search.id)) }
                catch { fputs("Harness search cancellation failed: \(error)\n", harnessStderr) }
            }
        }
        pending.removeAll()
    }
    func controlTextDidChange(_ obj: Notification) { searchChanged() }
    @objc private func searchChanged() {
        cancel(); results.removeAll(); nextOffsets.removeAll(); searchGenerations.removeAll(); errors.removeAll(); table.reloadData()
        moreButton.isEnabled = false
        let work = DispatchWorkItem { [weak self] in self?.startSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func startSearch() {
        searchedQuery = queryField.stringValue
        searchedCase = matchCase.state == .on
        guard !searchedQuery.isEmpty else { status.stringValue = "Search retained output in open sessions."; return }
        let owners = scope.indexOfSelectedItem == 0 ? SessionCoordinator.shared.connectedOwners : [sourceOwner]
        request(owners.map { ($0, 0) })
    }
    @objc private func loadMore() { request(nextOffsets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) }
    private func request(_ targets: [(String, Int)]) {
        let token = generation
        remaining = targets.count
        moreButton.isEnabled = false
        guard !targets.isEmpty else {
            status.stringValue = "No connected hosts to search. Connect a host and try again."
            return
        }
        status.stringValue = "Searching…"
        let query = searchedQuery, sensitive = searchedCase
        let session = scope.indexOfSelectedItem == 2 ? sourceSession : nil
        for (owner, offset) in targets {
            guard let endpoint = SessionCoordinator.shared.endpoint(forOwner: owner) else {
                receive(.failure(SetupError.invalid("Disconnected")), owner: owner, offset: offset, generation: token)
                continue
            }
            let id = UUID()
            let searchGeneration = searchGenerations[owner]
            pending.append((id, endpoint))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result<OutputSearchPage, Error> {
                    let response = try DaemonClient(endpoint: endpoint).request(.searchOutput(id: id, query: query, caseSensitive: sensitive, sessionID: session, offset: offset, generation: searchGeneration), timeout: 20)
                    if case let .error(message) = response { throw SetupError.invalid(message == "unrecognized request" ? "Update this host's daemon to search its output." : message) }
                    guard case let .text(json) = response else { throw SetupError.invalid("No search results returned") }
                    return try JSONDecoder().decode(OutputSearchPage.self, from: Data(json.utf8))
                }
                DispatchQueue.main.async { [weak self] in
                    self?.pending.removeAll { $0.id == id }
                    self?.receive(result, owner: owner, offset: offset, generation: token)
                }
            }
        }
    }
    private func receive(_ result: Result<OutputSearchPage, Error>, owner: String, offset: Int, generation token: Int) {
        guard generation == token else { return }
        remaining -= 1
        switch result {
        case let .success(page):
            searchGenerations[owner] = page.generation
            results.append(contentsOf: page.matches.map { (owner, $0, page.epoch, page.revision) })
            nextOffsets[owner] = page.hasMore ? offset + page.matches.count : nil
        case let .failure(error): errors.append("\(owner): \(error.localizedDescription)"); nextOffsets[owner] = nil
        }
        table.reloadData()
        if table.selectedRow < 0, !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        status.stringValue = "\(results.count) matching lines\(remaining > 0 ? " · Searching other hosts…" : "")\(errors.isEmpty ? "" : " · " + errors.joined(separator: " · "))"
        moreButton.isEnabled = remaining == 0 && !nextOffsets.isEmpty
    }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row], match = results[row].match
        let host = item.owner == DaemonSidebar.localID ? "This Mac" : item.owner
        let identifier = NSUserInterfaceItemIdentifier("outputMatch")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? OutputSearchResultCell ?? OutputSearchResultCell()
        cell.identifier = identifier
        cell.configure(excerpt: match.excerpt,
                       location: "\(host) · \(match.sessionName) · \(match.tabTitle) · Line \(match.line + 1)")
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = !openingResult && results.indices.contains(table.selectedRow)
    }

    @objc private func openResult() {
        guard !openingResult, results.indices.contains(table.selectedRow) else { return }
        let item = results[table.selectedRow]
        guard let endpoint = SessionCoordinator.shared.endpoint(forOwner: item.owner) else { return }
        let token = generation, query = searchedQuery, sensitive = searchedCase
        let id = UUID()
        pending.append((id, endpoint))
        openingResult = true
        openButton.isEnabled = false
        status.stringValue = "Checking result…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                let response = try DaemonClient(endpoint: endpoint).request(.validateOutputMatch(id: id, match: item.match, epoch: item.epoch, revision: item.revision), timeout: 10)
                guard case .ok = response else {
                    if case let .error(message) = response { throw SetupError.invalid(message) }
                    throw SetupError.invalid("Could not validate this result. Search again.")
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.pending.removeAll { $0.id == id }
                guard let self, generation == token else { return }
                openingResult = false
                openButton.isEnabled = results.indices.contains(table.selectedRow)
                do {
                    try result.get()
                    if SessionCoordinator.shared.openSearchResult(item.match, owner: item.owner, query: query, caseSensitive: sensitive) {
                        cancel()
                        window?.orderOut(nil)
                    } else { status.stringValue = "This output moved, expired, or is still loading. Search again to refresh its location." }
                } catch { status.stringValue = error.localizedDescription }
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) { openResult(); return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !results.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(results.count - 1, table.selectedRow + delta))
            table.selectRowIndexes([row], byExtendingSelection: false); table.scrollRowToVisible(row)
            return true
        }
        return false
    }
}

@MainActor
private final class OutputSearchResultCell: NSTableCellView {
    private let excerpt = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        excerpt.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        for label in [excerpt, location] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ])
        }
        NSLayoutConstraint.activate([
            excerpt.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            location.topAnchor.constraint(equalTo: excerpt.bottomAnchor, constant: 4),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            excerpt.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
            location.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
    }

    func configure(excerpt: String, location: String) {
        self.excerpt.stringValue = excerpt
        self.location.stringValue = location
        toolTip = "\(excerpt)\n\(location)"
        setAccessibilityLabel(toolTip)
    }
}
