import AppKit
import HarnessCore

/// Privacy controls belong to the selected host and capture the pane identity at opening.
@MainActor
final class HistoryPrivacyWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let endpoint: Endpoint
    private let pane: PaneLeaf?
    private let scope = NSPopUpButton()
    private let persist = HarnessToggle(title: "Persist captured history")
    private let apply = HarnessPillButton(title: "Apply privacy choice", kind: .primary)
    private let recover = HarnessPillButton(title: "Unlock and recover history…", kind: .secondary)
    private let status = NSTextField(wrappingLabelWithString: "Loading history policy…")
    private let workers = OperationQueue()
    private var generation = 0
    private var closed = false

    init(endpoint: Endpoint, pane: PaneLeaf?, owner: String) {
        self.endpoint = endpoint; self.pane = pane
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "History and privacy on " + owner
        super.init(window: window); window.delegate = self
        workers.maxConcurrentOperationCount = 1; workers.qualityOfService = .utility
        scope.addItems(withTitles: ["Selected terminal pane", "Host default (pane overrides remain)"])
        if pane == nil { scope.selectItem(at: 1); scope.item(at: 0)?.isEnabled = false }
        scope.target = self; scope.action = #selector(refresh)
        scope.setAccessibilityLabel("History persistence scope")
        persist.setAccessibilityLabel("Persist captured history in this scope")
        apply.target = self; apply.action = #selector(save)
        recover.target = self; recover.action = #selector(unlock)
        recover.isHidden = owner != DaemonSidebar.localID
        let refreshButton = HarnessToolPage.button("Refresh status", target: self, action: #selector(refresh))
        let explanation = NSTextField(wrappingLabelWithString: "Turning capture off removes associated captured text from saved scrollback, activity, digests, summaries and caches. Running programs and structural layout remain. Capture on macOS requires Keychain encryption; an unavailable key uses bounded memory and never writes plaintext. Enabling capture again cannot recover removed text.")
        let controls = NSStackView(views: [apply, refreshButton]); controls.spacing = 8
        let root = NSStackView(views: [scope, persist, explanation, controls, recover, status]); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 20, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(root)
        if let view = window.contentView {
            NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20), root.topAnchor.constraint(equalTo: view.topAnchor, constant: 20), root.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20), explanation.widthAnchor.constraint(equalTo: root.widthAnchor), status.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32)])
        }
        HarnessToolPage.group(root, title: "Capture policy", views: [scope, persist, explanation, controls]); HarnessToolPage.install(in: window, title: "History and privacy", subtitle: "Control captured text without interrupting your programs.", symbol: "lock.shield", content: root); window.center(); refresh()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; generation += 1; workers.cancelAllOperations(); onClose?() }

    private struct State: Sendable { var enabled: Bool; var message: String; var canRecover: Bool }
    private nonisolated static func fetch(_ endpoint: Endpoint, pane: PaneLeaf?, global: Bool) throws -> State {
        let client = DaemonClient(endpoint: endpoint)
        guard case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 2),
              case let .options(options) = try client.request(.showOptions(scope: nil), timeout: 2) else { throw DaemonClientError.unexpectedResponse }
        let history = options.filter { $0.key == "persist-scrollback" }
        let overridden = !global ? history.first { $0.scope == "pane" && ($0.target == pane?.surfaceID.uuidString || $0.target == pane?.id.uuidString) } : nil
        let value = overridden?.value ?? history.first { $0.scope == "global" }?.value ?? "on"
        let enabled = OptionStore.Value(parsing: value).boolValue
        let protection: String
        switch stats.historyProtection {
        case .keychainEncrypted: protection = "Keychain encrypted history."
        case .ownerOnlyLinux: protection = "Owner-only Linux storage; plaintext, not encrypted."
        case .keyUnavailable: protection = "History key unavailable. New captured output stays in bounded memory."
        case nil: protection = "This host does not report history protection. Update its application daemon before relying on encrypted history."
        }
        return State(enabled: enabled, message: protection + "\n" + (stats.historyUnavailable ?? "") + (!global && overridden == nil ? "\nThis pane currently inherits the host default. Applying sets an explicit pane choice." : ""), canRecover: stats.supports(DaemonStats.historyRecovery))
    }
    private func perform(_ work: @escaping @Sendable () throws -> State) {
        workers.cancelAllOperations()
        generation += 1; let ticket = generation
        apply.isEnabled = false; persist.isEnabled = false; recover.isEnabled = false
        status.stringValue = "Updating history policy…"
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, self.generation == ticket, !operation.isCancelled else { return }
                self.apply.isEnabled = true; self.persist.isEnabled = true
                switch result {
                case let .success(state): self.persist.state = state.enabled ? .on : .off; self.status.stringValue = state.message; self.recover.isEnabled = state.canRecover
                case let .failure(error): self.status.stringValue = error.localizedDescription
                }
            }
        }
        workers.addOperation(operation)
    }
    @objc private func refresh() {
        let endpoint = endpoint, pane = pane, global = scope.indexOfSelectedItem == 1
        perform { try Self.fetch(endpoint, pane: pane, global: global) }
    }
    @objc private func save() {
        let endpoint = endpoint, pane = pane, global = scope.indexOfSelectedItem == 1, enabled = persist.state == .on
        if !enabled {
            let alert = NSAlert(); alert.messageText = "Remove captured history in this scope?"
            alert.informativeText = "This removes associated saved text, activity messages, digest excerpts, summaries and caches. Programs keep running and layout remains. " + (global ? "Explicit pane overrides remain in effect." : "Only the selected terminal pane is affected.") + " Enabling capture again cannot recover removed text."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Turn capture off")
            guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { refresh(); return }
        }
        perform {
            let reply = try DaemonClient(endpoint: endpoint).request(.setOption(scope: global ? "global" : "pane", target: global ? nil : pane?.surfaceID.uuidString, key: "persist-scrollback", rawValue: enabled ? "on" : "off"), timeout: 10)
            if case let .error(message) = reply { throw SetupError.invalid(message) }
            guard case .ok = reply else { throw DaemonClientError.unexpectedResponse }
            var state = try Self.fetch(endpoint, pane: pane, global: global)
            state.message = "Privacy choice applied.\n" + state.message
            return state
        }
    }
    @objc private func unlock() {
        let endpoint = endpoint, pane = pane, global = scope.indexOfSelectedItem == 1
        perform {
            let protection = HistoryProtection.system(allowInteraction: true)
            guard protection.kind != .keyUnavailable else { throw HistoryProtectionError.keyUnavailable(protection.unavailableReason ?? "Unlock the history key before retrying.") }
            let reply = try DaemonClient(endpoint: endpoint).request(.retryHistory, timeout: 10)
            if case let .error(message) = reply { throw SetupError.invalid(message) }
            guard case .ok = reply else { throw DaemonClientError.unexpectedResponse }
            var state = try Self.fetch(endpoint, pane: pane, global: global)
            state.message = "History recovery completed.\n" + state.message
            return state
        }
    }
}
