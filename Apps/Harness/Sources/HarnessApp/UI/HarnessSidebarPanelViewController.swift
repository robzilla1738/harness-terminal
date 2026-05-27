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
    private var tabs: [Tab] = []
    private var activeWorkspaceID: WorkspaceID?
    private var isProgrammaticSelection = false

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

        let newTab = HarnessDesign.softIconButton(symbol: "plus", tooltip: "New tab")
        newTab.target = self
        newTab.action = #selector(addTab)

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

        footer.addSubview(newTab)
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
            newTab.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HarnessDesign.horizontalInset - 4),
            newTab.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newWS.leadingAnchor.constraint(equalTo: newTab.trailingAnchor, constant: 2),
            newWS.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
            palette.leadingAnchor.constraint(equalTo: newWS.trailingAnchor, constant: 2),
            palette.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
            settings.trailingAnchor.constraint(equalTo: help.leadingAnchor, constant: -2),
            settings.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
            help.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -(HarnessDesign.horizontalInset - 4)),
            help.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
        ])
    }

    @objc func reload() {
        let snap = SessionCoordinator.shared.snapshot
        workspaces = snap.workspaces
        activeWorkspaceID = snap.activeWorkspaceID
        tabs = snap.activeWorkspace?.tabs ?? []
        let name = snap.activeWorkspace?.name ?? "Workspace"
        workspacePill.configure(name: name, count: tabs.count)
        sessionTable.reloadData()

        if let activeTabID = snap.activeWorkspace?.activeTabID,
           let row = tabs.firstIndex(where: { $0.id == activeTabID })
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
        let newTabs = snap.activeWorkspace?.tabs ?? []
        let activeID = snap.activeWorkspace?.activeTabID
        // Structural changes still take the full reload path.
        if newTabs.map(\.id) != tabs.map(\.id) {
            reload()
            return
        }
        tabs = newTabs
        activeWorkspaceID = snap.activeWorkspaceID
        workspaces = snap.workspaces
        let name = snap.activeWorkspace?.name ?? "Workspace"
        workspacePill.configure(name: name, count: tabs.count)
        for row in 0 ..< tabs.count {
            if let cell = sessionTable.view(atColumn: 0, row: row, makeIfNecessary: false) as? SessionCardRowView {
                cell.configure(tab: tabs[row], isSelected: tabs[row].id == activeID)
            }
        }
    }

    @objc private func addWorkspace() {
        let count = SessionCoordinator.shared.snapshot.workspaces.count + 1
        SessionCoordinator.shared.addWorkspace(name: "Workspace \(count)")
    }

    @objc private func addTab() {
        guard let activeWorkspaceID else { return }
        SessionCoordinator.shared.addTab(to: activeWorkspaceID)
    }

    @objc private func sessionDoubleClick() {
        selectSessionRow()
    }

    @objc private func showWorkspaceMenu() {
        let menu = NSMenu()
        for workspace in workspaces {
            let item = NSMenuItem(title: workspace.name, action: #selector(workspaceMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = workspace.id
            item.state = workspace.id == activeWorkspaceID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let newItem = NSMenuItem(title: "New Workspace…", action: #selector(addWorkspace), keyEquivalent: "")
        newItem.target = self
        menu.addItem(newItem)
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: workspacePill)
        }
    }

    @objc private func workspaceMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WorkspaceID else { return }
        SessionCoordinator.shared.selectWorkspace(id)
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
        guard row >= 0, row < tabs.count, let activeWorkspaceID else { return }
        SessionCoordinator.shared.selectTab(workspaceID: activeWorkspaceID, tabID: tabs[row].id)
    }
}

extension HarnessSidebarPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tabs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let tab = tabs[row]
        let cell = SessionCardRowView()
        cell.configure(
            tab: tab,
            isSelected: tab.id == SessionCoordinator.shared.snapshot.activeWorkspace?.activeTabID
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        selectSessionRow()
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
    private let fill = NSView()
    private let statusDot = StatusDotView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let agentChip = AgentChipView()
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

        addSubview(fill)
        fill.addSubview(statusDot)
        fill.addSubview(titleLabel)
        fill.addSubview(metaLabel)
        fill.addSubview(agentChip)

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

            agentChip.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
            agentChip.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            agentChip.heightAnchor.constraint(equalToConstant: 18),

            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            metaLabel.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -10),
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

    func configure(tab: Tab, isSelected: Bool) {
        let folder = HarnessDesign.shortenPath(tab.cwd)
        let folderName = (folder as NSString).lastPathComponent.isEmpty ? folder : (folder as NSString).lastPathComponent
        titleLabel.stringValue = folderName

        var metaParts: [String] = []
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
