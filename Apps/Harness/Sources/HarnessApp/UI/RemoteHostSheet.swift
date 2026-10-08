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
    private let detectButton = HarnessPillButton(title: "Detect", kind: .secondary)
    private let testButton = HarnessPillButton(title: "Test Connection", kind: .secondary)
    private let saveButton = HarnessPillButton(title: "Save & Connect")
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
        let chrome = HarnessChrome.current
        window?.appearance = NSAppearance(named: chrome.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = chrome.sidebarBackground
        content.wantsLayer = true
        content.layer?.backgroundColor = chrome.sidebarBackground.cgColor

        let heading = NSTextField(labelWithString: editing == nil ? "Add remote host" : "Edit remote host")
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        heading.textColor = chrome.textPrimary
        let intro = NSTextField(wrappingLabelWithString: "Connect with your existing SSH keys or configuration.")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = chrome.textSecondary

        func field(_ field: NSTextField, placeholder: String) -> NSView {
            field.delegate = self
            field.font = .systemFont(ofSize: 13)
            field.textColor = chrome.textPrimary
            field.isBordered = false
            field.isBezeled = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: chrome.textTertiary, .font: field.font!]
            )
            field.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = chrome.surfaceElevated.cgColor
            container.layer?.borderColor = chrome.border.cgColor
            container.layer?.borderWidth = 1
            container.layer?.cornerRadius = HarnessDesign.Radius.card
            container.layer?.cornerCurve = .continuous
            container.addSubview(field)
            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 34),
                field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
                field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
                field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }
        let targetInput = field(targetField, placeholder: "user@host or SSH alias")
        let nameInput = field(nameField, placeholder: "Name shown in the sidebar")
        let optionsInput = field(optionsField, placeholder: "Optional, e.g. -p 2222 -J bastion")
        let socketInput = field(socketField, placeholder: "Detect automatically")

        detectButton.target = self
        detectButton.action = #selector(detect)
        detectButton.setAccessibilityLabel("Detect daemon socket")
        detectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        testButton.target = self
        testButton.action = #selector(test)
        testButton.setAccessibilityLabel("Test Connection")
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.setAccessibilityLabel("Save & Connect")
        saveButton.keyEquivalent = "\r"
        let cancel = HarnessPillButton(title: "Cancel", kind: .secondary)
        cancel.target = self
        cancel.action = #selector(RemoteHostSheet.cancel)
        cancel.setAccessibilityLabel("Cancel")
        cancel.keyEquivalent = "\u{1b}"

        status.font = .systemFont(ofSize: 12)
        status.textColor = HarnessChrome.current.textSecondary
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let socketRow = NSStackView(views: [socketInput, detectButton])
        socketRow.spacing = HarnessDesign.Spacing.sm
        let grid = NSGridView(views: [
            [label("SSH destination"), targetInput],
            [label("Name"), nameInput],
            [label("SSH options"), optionsInput],
            [label("Daemon socket"), socketRow],
        ])
        grid.rowSpacing = HarnessDesign.Spacing.lg
        grid.columnSpacing = HarnessDesign.Spacing.md
        grid.column(at: 0).xPlacement = .trailing
        grid.yPlacement = .center

        statusRow.setViews([spinner, status], in: .leading)
        statusRow.spacing = HarnessDesign.Spacing.sm
        statusRow.alignment = .top
        let buttons = NSStackView(views: [testButton, NSView(), cancel, saveButton])
        buttons.spacing = HarnessDesign.Spacing.md

        let stack = NSStackView(views: [heading, intro, grid, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = HarnessDesign.Spacing.lg
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            intro.widthAnchor.constraint(equalToConstant: 460),
            grid.widthAnchor.constraint(equalTo: intro.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: intro.widthAnchor),
            status.widthAnchor.constraint(lessThanOrEqualToConstant: 436),
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
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = HarnessChrome.current.textSecondary
        return label
    }

    // MARK: - Input

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.superview?.layer?.borderColor = HarnessChrome.current.focusRing.cgColor
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        field.superview?.layer?.borderColor = HarnessChrome.current.border.cgColor
    }

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
        for button in [detectButton, testButton, saveButton] {
            button.alphaValue = button.isEnabled ? 1 : 0.4
        }
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    private func show(_ message: String, tone: Tone = .neutral) {
        status.stringValue = message
        statusRow.isHidden = message.isEmpty
        fitWindow()
        switch tone {
        case .neutral: status.textColor = HarnessChrome.current.textSecondary
        case .good: status.textColor = HarnessChrome.current.success
        case .bad: status.textColor = HarnessChrome.current.danger
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
        show("Step 1 of 2 · Checking SSH and detecting the daemon on \(draft.trimmedTarget)…")
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
        show("Step 2 of 2 · Connecting to the daemon on \(host.sshTarget)…")
        let wasActive = SessionCoordinator.shared.isConnected(host.name)
        DispatchQueue.global(qos: .userInitiated).async {
            let message: String
            let ok: Bool
            do {
                let endpoint = try RemoteHostsService.shared.probe(host)
                let client = DaemonClient(endpoint: endpoint)
                guard case let .snapshot(snapshot) = try client.request(.getSnapshot, timeout: 3),
                      case let .daemonStats(stats) = try client.request(.daemonStats, timeout: 3) else {
                    throw SetupError.invalid("SSH connected, but the daemon did not answer. Detect the socket again or check the daemon on the host.")
                }
                let count = snapshot.workspaces.reduce(0) { $0 + $1.sessions.count }
                message = "Connected · Harness \(stats.version ?? "older version") · \(count) sessions.\nSurviving processes reconnect automatically. Local laptop sleep still pauses local work."
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
        // Edited settings must not ride the old forward.
        RemoteHostsService.shared.dropTunnelIfChanged(host)
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
