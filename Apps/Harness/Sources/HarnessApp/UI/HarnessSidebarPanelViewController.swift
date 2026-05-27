import AppKit
import HarnessCore

/// Left session rail — workspace pill, sessions list, and a quiet footer.
@MainActor
final class HarnessSidebarPanelViewController: NSViewController {
    private let chromeHeader = NSView()
    private let workspaceBar = NSView()
    private let workspacePill = WorkspacePillButton()
    private let sectionHeader = NSView()
    private let sectionLabel = NSTextField(labelWithString: "Sessions")
    private let sessionTable = NSTableView()
    private let footer = NSView()
    private var sessionScroll: NSScrollView?
    private var workspaces: [Workspace] = []
    private var sessions: [SessionGroup] = []
    private var activeWorkspaceID: WorkspaceID?
    private var activeSessionID: SessionID?
    private var isProgrammaticSelection = false
    private var workspaceDropdown: WorkspaceSwitcherPanelView?

    override func loadView() {
        let root = NSView()
        HarnessDesign.applySidebarChrome(to: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupChromeHeader()
        setupWorkspaceBar()
        setupSectionHeader()
        setupFooter()
        setupSessionList()
        reload()
        applyChromeColors()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reload),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
    }

    func applyChromeColors() {
        HarnessDesign.applySidebarChrome(to: view)
        HarnessDesign.makeClear(chromeHeader)
        HarnessDesign.makeClear(workspaceBar)
        HarnessDesign.makeClear(sectionHeader)
        HarnessDesign.makeClear(footer)
        sectionLabel.textColor = HarnessDesign.chrome.textTertiary
        workspacePill.applyChrome()
        workspaceDropdown?.removeFromSuperview()
        workspaceDropdown = nil
        for case let button as SoftIconButton in footer.subviews {
            button.applyChrome()
        }
        sessionTable.reloadData()
    }

    private func setupChromeHeader() {
        chromeHeader.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(chromeHeader)
        view.addSubview(chromeHeader)
        NSLayoutConstraint.activate([
            chromeHeader.topAnchor.constraint(equalTo: view.topAnchor),
            chromeHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chromeHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chromeHeader.heightAnchor.constraint(equalToConstant: HarnessDesign.titlebarChromeHeight),
        ])
    }

    private func setupWorkspaceBar() {
        workspaceBar.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(workspaceBar)

        workspacePill.target = self
        workspacePill.action = #selector(showWorkspaceMenu)
        workspacePill.translatesAutoresizingMaskIntoConstraints = false

        workspaceBar.addSubview(workspacePill)
        view.addSubview(workspaceBar)

        NSLayoutConstraint.activate([
            workspaceBar.topAnchor.constraint(equalTo: chromeHeader.bottomAnchor),
            workspaceBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            workspaceBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            workspaceBar.heightAnchor.constraint(equalToConstant: HarnessDesign.workspaceBarHeight),
            workspacePill.leadingAnchor.constraint(equalTo: workspaceBar.leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            workspacePill.trailingAnchor.constraint(equalTo: workspaceBar.trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),
            workspacePill.centerYAnchor.constraint(equalTo: workspaceBar.centerYAnchor),
            workspacePill.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func setupSectionHeader() {
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(sectionHeader)

        sectionLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        sectionLabel.stringValue = "SESSIONS"
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        sectionHeader.addSubview(sectionLabel)
        view.addSubview(sectionHeader)

        NSLayoutConstraint.activate([
            sectionHeader.topAnchor.constraint(equalTo: workspaceBar.bottomAnchor),
            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sectionHeader.heightAnchor.constraint(equalToConstant: 24),
            sectionLabel.leadingAnchor.constraint(equalTo: sectionHeader.leadingAnchor, constant: HarnessDesign.horizontalInset),
            sectionLabel.bottomAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: -4),
        ])
    }

    private func setupSessionList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = HarnessDesign.sidebarWidth
        sessionTable.addTableColumn(column)
        sessionTable.headerView = nil
        sessionTable.backgroundColor = .clear
        sessionTable.rowHeight = HarnessDesign.sessionRowHeight
        sessionTable.intercellSpacing = NSSize(width: 0, height: HarnessDesign.rowSpacing)
        sessionTable.selectionHighlightStyle = .none
        sessionTable.focusRingType = .none
        sessionTable.style = .plain
        sessionTable.dataSource = self
        sessionTable.delegate = self
        sessionTable.doubleAction = #selector(sessionDoubleClick)
        sessionTable.target = self

        let scroll = NSScrollView()
        scroll.documentView = sessionTable
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)

        sessionScroll = scroll
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
        ])
    }

    private func setupFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(footer)

        let newSession = HarnessDesign.softIconButton(symbol: "plus", tooltip: "New session")
        newSession.target = self
        newSession.action = #selector(addSession)

        let newWS = HarnessDesign.softIconButton(symbol: "folder.badge.plus", tooltip: "New workspace")
        newWS.target = self
        newWS.action = #selector(addWorkspace)

        let palette = HarnessDesign.softIconButton(symbol: "command", tooltip: "Command palette (⌘K)")
        palette.target = self
        palette.action = #selector(openPalette)

        let settings = HarnessDesign.softIconButton(symbol: "slider.horizontal.3", tooltip: "Settings (⌘,)")
        settings.target = self
        settings.action = #selector(openSettings)

        let help = HarnessDesign.softIconButton(symbol: "questionmark.circle", tooltip: "Agent hooks documentation")
        help.target = self
        help.action = #selector(openDocs)

        footer.addSubview(newSession)
        footer.addSubview(newWS)
        footer.addSubview(palette)
        footer.addSubview(settings)
        footer.addSubview(help)
        view.addSubview(footer)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: HarnessDesign.footerHeight),
            newSession.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            newSession.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newWS.leadingAnchor.constraint(equalTo: newSession.trailingAnchor, constant: 2),
            newWS.centerYAnchor.constraint(equalTo: newSession.centerYAnchor),
            palette.leadingAnchor.constraint(equalTo: newWS.trailingAnchor, constant: 2),
            palette.centerYAnchor.constraint(equalTo: newSession.centerYAnchor),
            settings.trailingAnchor.constraint(equalTo: help.leadingAnchor, constant: -2),
            settings.centerYAnchor.constraint(equalTo: newSession.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),
            help.centerYAnchor.constraint(equalTo: newSession.centerYAnchor),
        ])
    }

    @objc func reload() {
        let snap = SessionCoordinator.shared.snapshot
        workspaces = snap.workspaces
        activeWorkspaceID = snap.activeWorkspaceID
        activeSessionID = snap.activeWorkspace?.activeSessionID
        sessions = snap.activeWorkspace?.sessions ?? []
        let name = snap.activeWorkspace?.name ?? "Workspace"
        workspacePill.configure(name: name, count: sessions.count)
        sessionTable.reloadData()

        if let activeSessionID,
           let row = sessions.firstIndex(where: { $0.id == activeSessionID })
        {
            isProgrammaticSelection = true
            sessionTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isProgrammaticSelection = false
        }
    }

    /// Updates session card labels in place (title/cwd/branch/agent) without
    /// rebuilding the table — preserves selection + scroll position.
    func refreshMetadata() {
        let snap = SessionCoordinator.shared.snapshot
        let newSessions = snap.activeWorkspace?.sessions ?? []
        let activeID = snap.activeWorkspace?.activeSessionID
        // Structural changes still take the full reload path.
        if newSessions.map(\.id) != sessions.map(\.id) {
            reload()
            return
        }
        sessions = newSessions
        activeWorkspaceID = snap.activeWorkspaceID
        activeSessionID = activeID
        workspaces = snap.workspaces
        let name = snap.activeWorkspace?.name ?? "Workspace"
        workspacePill.configure(name: name, count: sessions.count)
        for row in 0 ..< sessions.count {
            if let cell = sessionTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCardRowView {
                cell.configure(session: sessions[row], isSelected: sessions[row].id == activeID)
            }
        }
    }

    @objc private func addWorkspace() {
        let count = SessionCoordinator.shared.snapshot.workspaces.count + 1
        SessionCoordinator.shared.addWorkspace(name: "Workspace \(count)")
    }

    @objc private func addSession() {
        guard let activeWorkspaceID else { return }
        SessionCoordinator.shared.addSession(to: activeWorkspaceID)
    }

    @objc private func sessionDoubleClick() {
        selectSessionRow()
    }

    @objc private func showWorkspaceMenu() {
        if let dropdown = workspaceDropdown {
            dropdown.removeFromSuperview()
            workspaceDropdown = nil
            return
        }
        let dropdown = WorkspaceSwitcherPanelView(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            onSelect: { [weak self] id in
                self?.workspaceDropdown?.removeFromSuperview()
                self?.workspaceDropdown = nil
                SessionCoordinator.shared.selectWorkspace(id)
            },
            onNew: { [weak self] in
                self?.workspaceDropdown?.removeFromSuperview()
                self?.workspaceDropdown = nil
                self?.addWorkspace()
            }
        )
        dropdown.alphaValue = 0
        dropdown.translatesAutoresizingMaskIntoConstraints = false
        dropdown.layer?.zPosition = 100
        view.addSubview(dropdown)
        workspaceDropdown = dropdown
        NSLayoutConstraint.activate([
            dropdown.topAnchor.constraint(equalTo: workspacePill.bottomAnchor, constant: 6),
            dropdown.leadingAnchor.constraint(equalTo: workspacePill.leadingAnchor),
            dropdown.trailingAnchor.constraint(equalTo: workspacePill.trailingAnchor),
            dropdown.heightAnchor.constraint(equalToConstant: dropdown.preferredHeight),
        ])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dropdown.animator().alphaValue = 1
        }
    }

    @objc private func openDocs() {
        if let url = URL(string: "https://github.com/robert/harness/blob/main/docs/agent-hooks/README.md") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openPalette() {
        if let window = view.window {
            CommandPaletteController.present(relativeTo: window)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.show()
    }

    private func selectSessionRow() {
        let row = sessionTable.selectedRow
        guard row >= 0, row < sessions.count, let activeWorkspaceID else { return }
        SessionCoordinator.shared.selectSession(workspaceID: activeWorkspaceID, sessionID: sessions[row].id)
    }

    private func confirmCloseSession(_ session: SessionGroup) {
        let title = session.name.isEmpty ? sessionTitle(for: session) : session.name
        let alert = NSAlert()
        alert.messageText = "Close session \"\(title)\"?"
        alert.informativeText = session.tabs.count > 1
            ? "This will close \(session.tabs.count) tabs and their running shells."
            : "This will close the session and its running shell."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Session")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if activeSessionID != session.id, let activeWorkspaceID {
            SessionCoordinator.shared.selectSession(workspaceID: activeWorkspaceID, sessionID: session.id)
        }
        SessionCoordinator.shared.closeActiveSession()
    }

    private func sessionTitle(for session: SessionGroup) -> String {
        guard let tab = session.activeTab ?? session.tabs.first else { return "Session" }
        return HarnessDesign.pathDisplayName(tab.cwd)
    }
}

extension HarnessSidebarPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        sessions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = sessions[row]
        let cell = SessionCardRowView()
        cell.configure(
            session: session,
            isSelected: session.id == SessionCoordinator.shared.snapshot.activeWorkspace?.activeSessionID
        )
        cell.onClose = { [weak self] in
            self?.confirmCloseSession(session)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        selectSessionRow()
    }
}

// MARK: - Workspace switcher

@MainActor
private final class WorkspaceSwitcherPanelView: NSView {
    private let workspaces: [Workspace]
    private let activeWorkspaceID: WorkspaceID?
    private let onSelect: (WorkspaceID) -> Void
    private let onNew: () -> Void
    let preferredHeight: CGFloat

    init(
        workspaces: [Workspace],
        activeWorkspaceID: WorkspaceID?,
        onSelect: @escaping (WorkspaceID) -> Void,
        onNew: @escaping () -> Void
    ) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.onSelect = onSelect
        self.onNew = onNew
        self.preferredHeight = max(72, CGFloat(33 * workspaces.count + 42))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        let c = HarnessDesign.chrome
        layer?.backgroundColor = (c.terminalBackground.blended(withFraction: c.isDark ? 0.04 : 0.035, of: c.textPrimary) ?? c.sidebarBackground).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.10 : 0.14).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.24
        layer?.shadowRadius = 18
        layer?.shadowOffset = NSSize(width: 0, height: -10)

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for workspace in workspaces {
            let row = WorkspaceSwitcherRow(
                title: workspace.name,
                count: workspace.sessions.count,
                isActive: workspace.id == activeWorkspaceID,
                symbol: "square.stack.3d.up"
            )
            row.onClick = { [onSelect] in onSelect(workspace.id) }
            stack.addArrangedSubview(row)
        }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = HarnessDesign.chrome.textPrimary.withAlphaComponent(0.08).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        stack.addArrangedSubview(divider)

        let newRow = WorkspaceSwitcherRow(
            title: "New Workspace...",
            count: nil,
            isActive: false,
            symbol: "folder.badge.plus"
        )
        newRow.onClick = onNew
        stack.addArrangedSubview(newRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

@MainActor
private final class WorkspaceSwitcherRow: NSButton {
    var onClick: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let check = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private let active: Bool

    init(title: String, count: Int?, isActive: Bool, symbol: String) {
        active = isActive
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        bezelStyle = .smallSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        if let count {
            countLabel.stringValue = "\(count)"
        }
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isHidden = count == nil

        let checkConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(checkConfig)
        check.translatesAutoresizingMaskIntoConstraints = false
        check.isHidden = !isActive

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(countLabel)
        addSubview(check)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 31),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.leadingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 16),
            countLabel.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -7),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            check.widthAnchor.constraint(equalToConstant: 14),
            check.heightAnchor.constraint(equalToConstant: 14),
        ])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    @objc private func clicked() {
        onClick?()
    }

    private func applyChrome() {
        let c = HarnessDesign.chrome
        let selectedFill = c.accent.withAlphaComponent(c.isDark ? 0.10 : 0.08)
        layer?.backgroundColor = active ? selectedFill.cgColor : (isHovered ? c.textPrimary.withAlphaComponent(0.055).cgColor : NSColor.clear.cgColor)
        layer?.borderWidth = active || isHovered ? 1 : 0
        layer?.borderColor = (active ? c.accent.withAlphaComponent(0.22) : c.textPrimary.withAlphaComponent(0.08)).cgColor
        icon.contentTintColor = active ? c.accent : c.textTertiary
        titleLabel.textColor = active || isHovered ? c.textPrimary : c.textSecondary
        countLabel.textColor = c.textTertiary
        check.contentTintColor = c.accent
    }
}

// MARK: - Workspace pill

@MainActor
final class WorkspacePillButton: NSButton {
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let countBadge = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let countBackground = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }

    init() {
        super.init(frame: .zero)
        title = ""
        bezelStyle = .inline
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(symbolConfig)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        countBackground.wantsLayer = true
        countBackground.layer?.cornerRadius = 4
        countBackground.layer?.cornerCurve = .continuous
        countBackground.translatesAutoresizingMaskIntoConstraints = false

        countBadge.font = .systemFont(ofSize: 10.5, weight: .semibold)
        countBadge.alignment = .center
        countBadge.translatesAutoresizingMaskIntoConstraints = false
        countBackground.addSubview(countBadge)

        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(countBackground)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: countBackground.leadingAnchor, constant: -6),
            countBackground.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            countBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            countBackground.heightAnchor.constraint(equalToConstant: 18),
            countBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            countBadge.leadingAnchor.constraint(equalTo: countBackground.leadingAnchor, constant: 6),
            countBadge.trailingAnchor.constraint(equalTo: countBackground.trailingAnchor, constant: -6),
            countBadge.centerYAnchor.constraint(equalTo: countBackground.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])

        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    func configure(name: String, count: Int) {
        nameLabel.stringValue = name
        countBadge.stringValue = "\(count)"
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessDesign.chrome
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = c.border.cgColor
        layer?.backgroundColor = isHovered ? c.iconHoverFill.cgColor : c.surfaceElevated.cgColor
        nameLabel.textColor = c.textPrimary
        icon.contentTintColor = c.textSecondary
        chevron.contentTintColor = c.textTertiary
        countBackground.layer?.backgroundColor = c.rowSelectedFill.cgColor
        countBadge.textColor = c.textSecondary
    }
}

// MARK: - Session card

@MainActor
final class SessionCardRowView: NSView {
    var onClose: (() -> Void)?

    private let fill = NSView()
    private let statusDot = StatusDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let agentChip = AgentChipView()
    private let closeButton = NSButton()
    private var isSelected = false
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        fill.wantsLayer = true
        fill.layer?.cornerRadius = HarnessDesign.cornerRadius
        fill.layer?.cornerCurve = .continuous
        fill.layer?.borderWidth = 1
        fill.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        metaLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        agentChip.translatesAutoresizingMaskIntoConstraints = false
        agentChip.isHidden = true

        let xConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close session")?
            .withSymbolConfiguration(xConfig)
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .smallSquare
        closeButton.setButtonType(.momentaryChange)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.alphaValue = 0
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 8
        closeButton.layer?.cornerCurve = .continuous

        addSubview(fill)
        fill.addSubview(statusDot)
        fill.addSubview(titleLabel)
        fill.addSubview(metaLabel)
        fill.addSubview(agentChip)
        fill.addSubview(closeButton)

        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),

            statusDot.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: 10),
            statusDot.topAnchor.constraint(equalTo: fill.topAnchor, constant: 13),

            titleLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 6),
            titleLabel.topAnchor.constraint(equalTo: fill.topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: agentChip.leadingAnchor, constant: -6),

            closeButton.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),

            agentChip.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6),
            agentChip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            agentChip.heightAnchor.constraint(equalToConstant: 18),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            metaLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: fill.bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func configure(session: SessionGroup, isSelected: Bool) {
        let tab = session.activeTab ?? session.tabs.first ?? Tab()
        let folder = HarnessDesign.shortenPath(tab.cwd)
        let folderName = HarnessDesign.pathDisplayName(tab.cwd)
        titleLabel.stringValue = session.name.isEmpty ? folderName : session.name

        var metaParts: [String] = []
        if session.tabs.count > 1 {
            metaParts.append("\(session.tabs.count) tabs")
        }
        if let branch = tab.gitBranch, !branch.isEmpty {
            metaParts.append(branch)
        }
        if tab.status == .waiting, let text = tab.notificationText, !text.isEmpty {
            metaParts.append(text)
        } else if !tab.title.isEmpty, tab.title != folderName, tab.title != "Shell" {
            metaParts.append(tab.title)
        } else {
            metaParts.append(folder)
        }
        metaLabel.stringValue = metaParts.joined(separator: "  •  ")

        switch tab.status {
        case .idle:
            // When the agent is generating, paint the dot with the agent's brand
            // color so users can scan a workspace for "what's running where" at
            // a glance.
            if let agent = tab.agent, agent.activity == .working {
                statusDot.style = .agent(hex: agent.kind.dotHex)
            } else {
                statusDot.style = .idle
            }
        case .waiting: statusDot.style = .waiting
        case .error: statusDot.style = .error
        }

        if let agent = tab.agent {
            agentChip.configure(text: agent.kind.chip, hex: agent.kind.dotHex)
            agentChip.isHidden = false
        } else {
            agentChip.isHidden = true
        }

        setSelected(isSelected)
    }

    @objc private func closeClicked() {
        onClose?()
    }

    private func setSelected(_ selected: Bool) {
        isSelected = selected
        refresh()
    }

    private func refresh() {
        let c = HarnessDesign.chrome
        metaLabel.textColor = c.textTertiary
        if isSelected {
            fill.layer?.backgroundColor = c.rowSelectedFill.cgColor
            fill.layer?.borderColor = c.border.cgColor
            titleLabel.textColor = c.textPrimary
            metaLabel.textColor = c.textSecondary
        } else if isHovered {
            fill.layer?.backgroundColor = c.rowHoverFill.cgColor
            fill.layer?.borderColor = NSColor.clear.cgColor
            titleLabel.textColor = c.textPrimary
        } else {
            fill.layer?.backgroundColor = NSColor.clear.cgColor
            fill.layer?.borderColor = NSColor.clear.cgColor
            titleLabel.textColor = c.textSecondary
        }
        statusDot.applyStyle()
        closeButton.alphaValue = (isHovered || isSelected) ? 1 : 0
        closeButton.contentTintColor = c.textTertiary
        closeButton.layer?.backgroundColor = (isHovered ? c.iconHoverFill : NSColor.clear).cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refresh()
    }
}
