import AppKit
import HarnessCore

/// Add or edit a remote host. The SSH destination is all most people type: the socket
/// path is detected over SSH, and Test Connection opens the tunnel and counts the remote
/// sessions before anything is saved.
@MainActor
final class RemoteHostSheet: NSWindowController, NSTextFieldDelegate {
    private static var open: RemoteHostSheet?

    /// `editing` prefills the fields; saving replaces that host (it may be renamed).
    static func present(editing: RemoteHost? = nil, prefill: RemoteHost? = nil) {
        open?.close()
        let sheet = RemoteHostSheet(editing: editing, prefill: prefill)
        open = sheet
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow, parent.attachedSheet == nil {
            parent.beginSheet(sheet.window!)
        } else {
            sheet.window?.center()
            sheet.showWindow(nil)
        }
    }

    private let editing: RemoteHost?
    private let nameField = NSTextField()
    private let targetField = NSTextField()
    private let optionsField = NSTextField()
    private let socketField = NSTextField()
    private let detectButton = NSButton(title: "Detect", target: nil, action: nil)
    private let testButton = NSButton(title: "Test Connection", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save & Connect", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let statusRow = NSStackView()
    private var nameEdited = false
    private var busy = false { didSet { updateButtons() } }

    private init(editing: RemoteHost?, prefill: RemoteHost?) {
        self.editing = editing
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = editing == nil ? "Add Remote Host" : "Edit Remote Host"
        super.init(window: window)
        build()
        let seed = editing ?? prefill
        if let seed {
            nameField.stringValue = seed.name
            targetField.stringValue = seed.sshTarget
            optionsField.stringValue = seed.sshArgs.joined(separator: " ")
            socketField.stringValue = seed.remoteSocketPath
            nameEdited = !seed.name.isEmpty
        }
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let intro = NSTextField(wrappingLabelWithString: "Harness reaches the other machine's daemon through your own SSH (keys or agent, your ~/.ssh/config). Nothing new to sign in to.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor

        func field(_ field: NSTextField, placeholder: String) {
            field.placeholderString = placeholder
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
        }
        field(targetField, placeholder: "user@host or a ~/.ssh/config alias")
        field(nameField, placeholder: "Shown in the sidebar and switcher")
        field(optionsField, placeholder: "Optional, e.g. -p 2222 -J bastion")
        field(socketField, placeholder: "Filled in by Detect")

        detectButton.target = self
        detectButton.action = #selector(detect)
        detectButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(test)
        testButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let socketRow = NSStackView(views: [socketField, detectButton])
        socketRow.spacing = HarnessDesign.Spacing.sm
        let grid = NSGridView(views: [
            [label("SSH destination"), targetField],
            [label("Name"), nameField],
            [label("SSH options"), optionsField],
            [label("Daemon socket"), socketRow],
        ])
        grid.rowSpacing = HarnessDesign.Spacing.md
        grid.columnSpacing = HarnessDesign.Spacing.md
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline

        statusRow.setViews([spinner, status], in: .leading)
        statusRow.spacing = HarnessDesign.Spacing.sm
        statusRow.alignment = .top
        let buttons = NSStackView(views: [testButton, NSView(), cancel, saveButton])
        buttons.spacing = HarnessDesign.Spacing.md

        let stack = NSStackView(views: [intro, grid, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HarnessDesign.Spacing.lg
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: 420),
            targetField.widthAnchor.constraint(equalToConstant: 300),
            buttons.widthAnchor.constraint(equalTo: intro.widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 396),
        ])
        window?.initialFirstResponder = targetField
        statusRow.isHidden = true
        fitWindow()
    }

    /// The panel hugs its content, growing a line when the status has something to say.
    private func fitWindow() {
        guard let content = window?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(content.fittingSize)
    }

    private func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    // MARK: - Input

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === nameField { nameEdited = !nameField.stringValue.isEmpty }
        if field === targetField, !nameEdited {
            nameField.stringValue = RemoteHostDraft.suggestedName(forTarget: targetField.stringValue)
        }
        updateButtons()
    }

    private var draft: RemoteHostDraft {
        RemoteHostDraft(
            name: nameField.stringValue,
            target: targetField.stringValue,
            options: optionsField.stringValue,
            socket: socketField.stringValue
        )
    }

    private func updateButtons() {
        let hasTarget = !draft.trimmedTarget.isEmpty
        detectButton.isEnabled = hasTarget && !busy
        testButton.isEnabled = hasTarget && !busy
        saveButton.isEnabled = hasTarget && !draft.trimmedName.isEmpty && !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func show(_ message: String, tone: Tone = .neutral) {
        status.stringValue = message
        statusRow.isHidden = message.isEmpty
        fitWindow()
        switch tone {
        case .neutral: status.textColor = .secondaryLabelColor
        case .good: status.textColor = .systemGreen
        case .bad: status.textColor = .systemRed
        }
    }

    private enum Tone { case neutral, good, bad }
    private enum DetectOutcome: Sendable { case found(String), failed(String) }

    // MARK: - Actions

    @objc private func detect() {
        runDetect { _ in }
    }

    /// Finds the socket over SSH, fills the field, then calls `next` with the result.
    private func runDetect(then next: @escaping @MainActor (Bool) -> Void) {
        let draft = self.draft
        busy = true
        show("Looking for the Harness daemon on \(draft.trimmedTarget)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: DetectOutcome
            do {
                outcome = .found(try RemoteSocketDetector.detect(target: draft.trimmedTarget, sshArgs: draft.sshArgs))
            } catch {
                outcome = .failed("\(error)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    switch outcome {
                    case let .found(path):
                        self.socketField.stringValue = path
                        self.show("Found the daemon at \(path).", tone: .good)
                        next(true)
                    case let .failed(message):
                        self.show(message, tone: .bad)
                        next(false)
                    }
                }
            }
        }
    }

    @objc private func test() {
        if draft.trimmedSocket.isEmpty {
            runDetect { [weak self] found in if found { self?.test() } }
            return
        }
        guard let host = draft.host else {
            show("Check the SSH destination and options.", tone: .bad)
            return
        }
        busy = true
        show("Connecting to \(host.sshTarget)…")
        let wasActive = RemoteHostsService.shared.activeHostName == host.name
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            let ok: Bool
            do {
                let endpoint = try RemoteHostsService.shared.probe(host)
                let count = RemoteHostsService.sessionCount(at: endpoint)
                message = "Connected. \(count) session\(count == 1 ? "" : "s") on \(host.sshTarget)."
                ok = true
            } catch {
                message = "\(error)"
                ok = false
            }
            // A test doesn't leave a tunnel behind for a host the window isn't using.
            if !wasActive { SSHTunnelManager.shared.stop(host: host.name) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    self.show(message, tone: ok ? .good : .bad)
                }
            }
        }
    }

    @objc private func save() {
        if draft.trimmedSocket.isEmpty {
            runDetect { [weak self] found in if found { self?.save() } }
            return
        }
        guard let host = draft.host else {
            show("Check the SSH destination and options.", tone: .bad)
            return
        }
        if let editing, editing.name != host.name {
            RemoteHostsService.shared.removeHost(named: editing.name)
        }
        guard RemoteHostsService.shared.addHost(host) else {
            show("Couldn't write remote-hosts.json. Check disk space and permissions.", tone: .bad)
            return
        }
        finish()
        SessionCoordinator.shared.connectToRemote(named: host.name)
    }

    @objc private func cancel() { finish() }

    private func finish() {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window?.close()
        }
        Self.open = nil
    }
}
