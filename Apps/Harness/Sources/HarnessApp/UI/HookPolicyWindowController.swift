import AppKit
import HarnessCore

@MainActor
final class HookPolicyWindowController: NSWindowController, NSWindowDelegate {
    private let endpoint: Endpoint
    private let choices = HarnessSelect(), details = NSTextView(), status = NSTextField(wrappingLabelWithString: "Policies require explicit local trust. Hooks are guardrails, not a complete shell security boundary.")
    private var records: [TrustedHookPolicy] = [], closed = false
    private var busy = false { didSet { policyActions.forEach { $0.isEnabled = selected != nil && !busy } } }
    private var policyActions: [NSButton] = []
    private let workers = OperationQueue()
    var onClose: (() -> Void)?
    init(endpoint: Endpoint) {
        self.endpoint = endpoint
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 620), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window); window.title = "Trusted hook policy"; window.delegate = self; window.minSize = NSSize(width: 640, height: 480); workers.maxConcurrentOperationCount = 1; workers.qualityOfService = .utility
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.edgeInsets = .init(top: 16, left: 16, bottom: 16, right: 16)
        let row = HarnessToolPage.actionRows([HarnessToolPage.button("Review policy file…", target: self, action: #selector(reviewFile)), HarnessToolPage.button("Enable / disable…", target: self, action: #selector(toggle)), HarnessToolPage.button("Refresh", target: self, action: #selector(reload))]); row.spacing = 8; root.addArrangedSubview(row)
        choices.emptyTitle = "No trusted policies"; choices.target = self; choices.action = #selector(select); choices.setAccessibilityLabel("Explicitly trusted local policies"); root.addArrangedSubview(choices)
        let controls = HarnessToolPage.actionRows([HarnessToolPage.button("Preview hook installation…", target: self, action: #selector(install)), HarnessToolPage.button("Remove installed hook…", target: self, action: #selector(uninstall)), HarnessToolPage.button("Redacted audit", target: self, action: #selector(audit))]); controls.spacing = 8; root.addArrangedSubview(controls)
        for group in [row, controls] {
            for actions in group.arrangedSubviews.compactMap({ $0 as? NSStackView }) {
                policyActions += actions.arrangedSubviews.compactMap { $0 as? NSButton }.filter { $0.action == #selector(toggle) || $0.action == #selector(install) || $0.action == #selector(uninstall) }
            }
        }
        policyActions.forEach { $0.isEnabled = false }
        root.addArrangedSubview(NSTextField(wrappingLabelWithString: "Literal conditions never execute code or regex. Claude requires 2.1.295+ for failure blocking. Cursor ask uses its shell/MCP permission events. Codex fail-closed enforcement is unsupported by its current documented failure behavior."))
        details.isEditable = false; details.isSelectable = true; details.font = .monospacedSystemFont(ofSize: 12, weight: .regular); details.isVerticallyResizable = true; details.autoresizingMask = [.width]; details.setAccessibilityLabel("Reviewed literal rules, installed-hook diff or redacted evaluated-decision audit")
        let scroll = NSScrollView(); scroll.documentView = details; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true; root.addArrangedSubview(scroll); root.addArrangedSubview(status)
        for view in root.arrangedSubviews { view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true }; window.contentView = root; HarnessToolPage.group(root, title: "Policy and audit", views: [scroll]); HarnessToolPage.install(in: window, title: "Hook policy", subtitle: "Review trusted guardrails and their recorded decisions.", symbol: "shield.lefthalf.filled", content: root); window.center(); reload()
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { closed = true; workers.cancelAllOperations(); onClose?() }
    private var selected: TrustedHookPolicy? { records.indices.contains(choices.indexOfSelectedItem) ? records[choices.indexOfSelectedItem] : nil }
    private func json<T: Encodable>(_ value: T) throws -> String { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return String(decoding: try encoder.encode(value), as: UTF8.self) }
    @objc private func reload() {
        do { let id = selected?.id; records = try HookPolicyRegistry.load(); choices.removeAllItems(); choices.addItems(withTitles: records.map { $0.policy.name + ($0.policy.enabled ? " · enabled" : " · disabled") }); if let id, let index = records.firstIndex(where: { $0.id == id }) { choices.selectItem(at: index) }; select() }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func select() {
        policyActions.forEach { $0.isEnabled = selected != nil && !busy }
        details.string = selected.flatMap { try? json($0) } ?? "No explicitly trusted policy. Review a local declarative JSON policy to begin."
    }
    private func approve(_ policy: HookPolicy) {
        do {
            try policy.validate(); let alert = NSAlert(); alert.messageText = policy.enabled ? "Trust and enable these rules?" : "Trust these disabled rules?"; alert.informativeText = "Review every literal condition. Installation remains a separate reviewed step; provider trust is never automatically approved.\n\n" + (try json(policy)); alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: policy.enabled ? "Trust and Enable" : "Trust Disabled")
            guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }; try HookPolicyRegistry.approve(policy); reload(); status.stringValue = "Reviewed policy stored with a private backup. Preview installation to wire its provider hooks."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func reviewFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; guard panel.runModal() == .OK, let url = panel.url else { return }
        do { guard let data = try PrivateFile.read(url, maximumBytes: 256 << 10) else { throw HookPolicyError.missing }; approve(try JSONDecoder().decode(HookPolicy.self, from: data)) } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func toggle() { guard var policy = selected?.policy else { return }; policy.enabled.toggle(); approve(policy) }
    @objc private func install() { prepareInstallation(remove: false) }
    @objc private func uninstall() { prepareInstallation(remove: true) }
    private func prepareInstallation(remove: Bool) {
        guard !busy, let policy = selected?.policy, let cli = HarnessCLILocator.url() else { status.stringValue = "Select a trusted policy and install the Harness CLI first."; return }
        var providerExecutable: URL?
        if policy.contract == .claude202610, !remove {
            let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.message = "Choose the installed Claude CLI to verify support for onFailure: block (2.1.295+)."; guard panel.runModal() == .OK, let url = panel.url else { return }; providerExecutable = url
        }
        busy = true; let executable = providerExecutable; status.stringValue = "Preparing bounded hook configuration preview…"
        workers.addOperation { [weak self] in
            let result = Result {
                let version: String?
                if let executable { let output = try ProcessCapture.run(executable, arguments: ["--version"], timeout: 2, maxOutputBytes: 1024); guard output.status == 0 else { throw HookPolicyError.unsupported("Could not verify provider version.") }; version = String(decoding: output.stdout, as: UTF8.self) } else { version = nil }
                return try HookPolicyInstallation.prepare(policy: policy, executable: cli, providerVersion: version, remove: remove)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed else { return }; self.busy = false
                do {
                    let proposal = try result.get(); self.details.string = proposal.diff + "\n\n" + proposal.trustNotice
                    let alert = NSAlert(); alert.messageText = remove ? "Remove this installed policy hook?" : "Apply this reviewed hook configuration?"; alert.informativeText = proposal.url.path + "\n" + proposal.trustNotice + "\n\n" + proposal.diff; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: remove ? "Remove Hook" : "Apply Hook Configuration")
                    guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
                    guard try HookPolicyRegistry.load().contains(where: { $0.policy == policy }) else { throw HookPolicyError.missing }
                    let backup = try HookPolicyInstallation.apply(proposal); self.status.stringValue = "Changed " + proposal.url.path + (backup.map { "; backup: " + $0.path } ?? "") + ". Review through the provider's hook trust UI before relying on enforcement."
                } catch { self.status.stringValue = error.localizedDescription }
            }
        }
    }
    @objc private func audit() {
        guard !busy else { return }; busy = true; let endpoint = endpoint
        workers.addOperation { [weak self] in
            let result = Result { () throws -> String in
                let response = try DaemonClient(endpoint: endpoint).request(.activity(.hookPolicy(.audit(offset: 0, limit: 100))), timeout: 10)
                if case let .error(message) = response { throw HookPolicyError.unsupported(message) }; guard case let .text(text) = response else { throw DaemonClientError.unexpectedResponse }; return text
            }
            DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.busy = false; do { self.details.string = try result.get(); self.status.stringValue = "First 100 retained evaluated decisions. Delivery and actual tool execution are separate; use hook-policy audit --offset for older pages. No raw tool inputs are recorded." } catch { self.status.stringValue = error.localizedDescription } }
        }
    }
}
