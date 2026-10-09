import AppKit
import HarnessCore
import HarnessTerminalEngine

/// Left rail in sidebar mode: sessions headed by name, each with its tabs beneath, a
/// toggle and "+" on the traffic-light row, and filter / agents / new / remote below.
@MainActor
final class HarnessSidebarPanelViewController: NSViewController {
    /// The session this window shows; set by `MainSplitViewController`.
    var context = WindowContext()

    private let chromeHeader = NSView()
    private let workspaceBar = NSView()
    private let workspacePill = WorkspacePillButton()
    private let notificationBell = NotificationBellButton()
    /// Collapses the sidebar (⌘\). Lives at the sidebar's top-trailing edge, against
    /// the divider; when the sidebar is collapsed it's gone with it (re-open via ⌘\).
    /// Flat `.plain` style + 30×30 so it matches the neighbouring notification bell.
    private let sidebarToggleButton = SoftIconButton(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
    /// Plain editable field (not `NSSearchField`): a borderless `NSSearchField` collapses
    /// its built-in search-button cell when it becomes first responder, which shifts the
    /// text/insertion-point left over the placeholder and drops the magnifier — the
    /// "messes up on click" glitch. A bare `NSTextField` + a static magnifier image view
    /// has no such cell to collapse, so focus is rock-steady.
    private let searchField = NSTextField()
    private let searchIcon = NSImageView()
    /// Wraps the search field so it gets the same radius-7 elevated-surface chrome as
    /// the workspace pill and session cards.
    private let searchContainer = NSView()
    private let sectionHeader = NSView()
    private let sectionLabel = NSTextField(labelWithString: "Sessions")
    private let sessionTable = NSTableView()
    private let footer = NSView()
    /// Opens the shared per-pane Activity popover. Stored so
    /// the popover can anchor to it. Created in `setupFooter`.
    private let agentsButton = HarnessDesign.softIconButton(symbol: "sparkles", tooltip: "Activity")
    private var sessionScroll: NSScrollView?
    private var workspaces: [Workspace] = []
    private var sessions: [SessionGroup] = []
    private var activeWorkspaceID: WorkspaceID?
    private var activeSessionID: SessionID?
    private var isProgrammaticSelection = false
    private var workspaceDropdown: WorkspaceSwitcherPanelView?
    private var workspaceDropdownMonitor: Any?
    /// Live filter text from the search field; empty shows all sessions.
    private var sessionFilter = ""
    /// What the list shows, top to bottom (see `SidebarOutline`).
    private var outline: [SidebarOutlineLine] = []
    private let newTabButton = SoftIconButton(frame: .zero)
    private var searchHeight: NSLayoutConstraint!

    /// Sessions after applying the search filter. Drag-reorder is disabled while a
    /// filter is active (see the data source), so callers that reorder still use the
    /// unfiltered `sessions`.
    private var displayedSessions: [SessionGroup] {
        let q = sessionFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { sessionMatches($0, query: q) }
    }

    private func sessionMatches(_ session: SessionGroup, query: String) -> Bool {
        if session.name.lowercased().contains(query) { return true }
        for tab in session.tabs {
            if tab.title.lowercased().contains(query) { return true }
            if tab.cwd.lowercased().contains(query) { return true }
            if HarnessDesign.pathDisplayName(tab.cwd).lowercased().contains(query) { return true }
        }
        return false
    }

    override func loadView() {
        let root = NSView()
        root.menu = MainMenuBuilder.chromeContextMenu()
        HarnessDesign.applySidebarChrome(to: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupChromeHeader()
        setupWorkspaceBar()
        setupSearchField()
        setupSectionHeader()
        setupFooter()
        setupSessionList()
        reload()
        applyChromeColors()
        // The window's split controller reloads this once per snapshot, after its context is current.
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncSessionColumnWidth()
    }

    func applyChromeColors() {
        HarnessDesign.applySidebarChrome(to: view)
        HarnessDesign.makeClear(chromeHeader)
        HarnessDesign.makeClear(workspaceBar)
        HarnessDesign.makeClear(sectionHeader)
        HarnessDesign.makeClear(footer)
        sectionLabel.textColor = HarnessDesign.chrome.textSecondary
        HarnessDesign.applyChromeLabelAppearance([sectionLabel], isDark: HarnessDesign.chrome.isDark)
        workspacePill.applyChrome()
        sidebarToggleButton.applyChrome()
        dismissWorkspaceDropdown()
        for case let button as SoftIconButton in footer.subviews {
            button.applyChrome()
        }
        applySearchChrome()
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
            chromeHeader.heightAnchor.constraint(equalToConstant: HarnessDesign.tabBarHeight),
        ])
    }

    /// The sidebar header row: the search field with the notification bell + sidebar toggle
    /// to its right. Workspaces are deliberately not surfaced here (single active workspace);
    /// the switcher machinery stays dormant so it can be re-enabled later. The search field
    /// itself is added in `setupSearchField` (it slots into the leading space of this row).
    private func setupWorkspaceBar() {
        workspaceBar.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(workspaceBar)

        notificationBell.translatesAutoresizingMaskIntoConstraints = false
        notificationBell.target = self
        notificationBell.action = #selector(notificationBellClicked)

        sidebarToggleButton.style = .glyph
        sidebarToggleButton.setSymbol("sidebar.left", accessibilityDescription: "Hide sidebar", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        sidebarToggleButton.toolTip = "Hide sidebar (⌘\\)"
        sidebarToggleButton.target = self
        sidebarToggleButton.action = #selector(sidebarToggleClicked)
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false

        newTabButton.style = .glyph
        newTabButton.setSymbol("plus", accessibilityDescription: "New tab", pointSize: HarnessDesign.chromeIconPointSize, weight: .medium)
        newTabButton.toolTip = "New tab (⌘T)"
        newTabButton.target = self
        newTabButton.action = #selector(addTab)
        newTabButton.translatesAutoresizingMaskIntoConstraints = false

        // Toggle after the traffic lights, bell and "+" at the trailing edge.
        chromeHeader.addSubview(sidebarToggleButton)
        chromeHeader.addSubview(newTabButton)
        chromeHeader.addSubview(notificationBell)
        view.addSubview(workspaceBar)

        let control = HarnessDesign.chromeIconButtonSize
        searchHeight = workspaceBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            workspaceBar.topAnchor.constraint(equalTo: chromeHeader.bottomAnchor),
            workspaceBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            workspaceBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchHeight,
            sidebarToggleButton.leadingAnchor.constraint(equalTo: chromeHeader.leadingAnchor, constant: HarnessDesign.trafficLightClearance),
            sidebarToggleButton.centerYAnchor.constraint(equalTo: chromeHeader.topAnchor, constant: HarnessDesign.titleRowCenter),
            sidebarToggleButton.widthAnchor.constraint(equalToConstant: control),
            sidebarToggleButton.heightAnchor.constraint(equalToConstant: control),
            newTabButton.trailingAnchor.constraint(equalTo: chromeHeader.trailingAnchor, constant: -HarnessDesign.Spacing.md),
            newTabButton.centerYAnchor.constraint(equalTo: chromeHeader.topAnchor, constant: HarnessDesign.titleRowCenter),
            newTabButton.widthAnchor.constraint(equalToConstant: control),
            newTabButton.heightAnchor.constraint(equalToConstant: control),
            notificationBell.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -HarnessDesign.Spacing.xs),
            notificationBell.centerYAnchor.constraint(equalTo: chromeHeader.topAnchor, constant: HarnessDesign.titleRowCenter),
            notificationBell.widthAnchor.constraint(equalToConstant: HarnessDesign.chromeIconButtonSize),
            notificationBell.heightAnchor.constraint(equalToConstant: HarnessDesign.chromeIconButtonSize),
        ])
    }

    @objc private func addTab() {
        guard let activeWorkspaceID else { return }
        SessionCoordinator.shared.addTab(to: activeWorkspaceID)
    }

    @objc private func sidebarToggleClicked() {
        (view.window?.contentViewController as? MainSplitViewController)?.toggleSidebar()
    }

    @objc private func notificationBellClicked() {
        showAgentsInbox(needsAttention: true)
    }

    @objc private func agentsButtonClicked() {
        showAgentsInbox()
    }

    private var agentsInbox: AgentInboxPanelView?
    private var agentsInboxMonitor: Any?

    private func showAgentsInbox(needsAttention: Bool = false) {
        if agentsInbox != nil {
            dismissAgentsInbox()
            return
        }
        let coordinator = SessionCoordinator.shared
        let inbox = AgentInboxPanelView(
            needsAttention: needsAttention,
            onSelect: { [weak self] agent in
                self?.dismissAgentsInbox()
                coordinator.openAttention(agent)
            }
        )
        inbox.alphaValue = 0
        inbox.translatesAutoresizingMaskIntoConstraints = true
        inbox.layer?.zPosition = 100

        let host = view.window?.contentView ?? view
        let width: CGFloat = 430
        let height = inbox.preferredHeight
        let button = host.convert(agentsButton.bounds, from: agentsButton)
        var originX = button.minX
        originX = min(originX, host.bounds.maxX - width - 8)
        originX = max(8, originX)
        // Footer sits at the bottom; the content view is not flipped (y grows upward), so
        // the panel sits *above* the button when its bottom edge is just above the button.
        let originY = button.maxY + 6
        inbox.frame = NSRect(x: originX, y: originY, width: width, height: height)
        host.addSubview(inbox)
        agentsInbox = inbox
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : HarnessDesign.Motion.microFast
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            inbox.animator().alphaValue = 1
        }
        installAgentsInboxMonitor()
    }

    private func dismissAgentsInbox() {
        agentsInbox?.removeFromSuperview()
        agentsInbox = nil
        if let monitor = agentsInboxMonitor {
            NSEvent.removeMonitor(monitor)
            agentsInboxMonitor = nil
        }
    }

    private func installAgentsInboxMonitor() {
        agentsInboxMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let inbox = self.agentsInbox else { return event }
            let point = inbox.convert(event.locationInWindow, from: nil)
            if !inbox.bounds.contains(point) {
                let buttonPoint = self.agentsButton.convert(event.locationInWindow, from: nil)
                if !self.agentsButton.bounds.contains(buttonPoint) {
                    self.dismissAgentsInbox()
                }
            }
            return event
        }
    }

    private func setupSectionHeader() {
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(sectionHeader)

        sectionLabel.font = HarnessDesign.Typography.sectionLabel
        sectionLabel.stringValue = "SESSIONS"
        HarnessDesign.prepareChromeLabel(sectionLabel)
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false

        sectionLabel.isHidden = true
        sectionHeader.addSubview(sectionLabel)
        view.addSubview(sectionHeader)

        NSLayoutConstraint.activate([
            sectionHeader.topAnchor.constraint(equalTo: workspaceBar.bottomAnchor),
            sectionHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sectionHeader.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Sessions head their own groups now; the old "WORKSPACE" label stays collapsed.
            sectionHeader.heightAnchor.constraint(equalToConstant: 0),
            sectionLabel.leadingAnchor.constraint(equalTo: sectionHeader.leadingAnchor, constant: HarnessDesign.horizontalInset),
            sectionLabel.bottomAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: -4),
        ])
    }

    /// Warp-style "Search sessions…" field; filters the list live by name / cwd.
    private func setupSearchField() {
        searchContainer.wantsLayer = true
        searchContainer.layer?.cornerRadius = HarnessDesign.Radius.card
        searchContainer.layer?.cornerCurve = .continuous
        searchContainer.layer?.borderWidth = 1
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        // Static magnifier accessory; the container owns the rounded-rect chrome so the
        // icon + text sit on our standardized surface (matching the pill).
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil
        )
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        searchIcon.imageScaling = .scaleProportionallyDown
        searchIcon.contentTintColor = HarnessChrome.current.textSecondary

        // Borderless/clear single-line editable field; live filtering via the delegate
        // (`controlTextDidChange`), not a target/action (which only fires on Enter).
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.usesSingleLineMode = true
        searchField.lineBreakMode = .byTruncatingTail
        searchField.cell?.isScrollable = true
        searchField.cell?.wraps = false
        searchField.font = HarnessDesign.Typography.sidebarLabel
        searchField.focusRingType = .none
        searchField.delegate = self

        searchContainer.addSubview(searchIcon)
        searchContainer.addSubview(searchField)
        // The search field lives in the header row, expanding from the leading edge up to the
        // notification bell + sidebar toggle on the right.
        // Revealed by the footer's filter button.
        searchContainer.isHidden = true
        workspaceBar.addSubview(searchContainer)
        NSLayoutConstraint.activate([
            searchContainer.leadingAnchor.constraint(equalTo: workspaceBar.leadingAnchor, constant: HarnessDesign.Spacing.md),
            searchContainer.trailingAnchor.constraint(equalTo: workspaceBar.trailingAnchor, constant: -HarnessDesign.Spacing.md),
            searchContainer.centerYAnchor.constraint(equalTo: workspaceBar.centerYAnchor),
            searchContainer.heightAnchor.constraint(equalToConstant: 28),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 8),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -6),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
        ])
    }

    private func applySearchChrome() {
        let c = HarnessChrome.current
        searchContainer.layer?.backgroundColor = c.surfaceElevated.cgColor
        // Defined card rim to match the workspace pill + session cards (one component family).
        searchContainer.layer?.borderColor = c.borderStrong.cgColor
        // Typed text + placeholder share the standardized label font, and the
        // placeholder uses the same resting color as the workspace name so the two
        // header rows read as identical type.
        searchField.textColor = c.textPrimary
        searchIcon.contentTintColor = c.textSecondary
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Filter sessions and tabs…",
            attributes: [
                .foregroundColor: c.textSecondary,
                .font: HarnessDesign.Typography.sidebarLabel,
            ]
        )
    }

    private func searchChanged() {
        sessionFilter = searchField.stringValue
        reload()
    }

    @objc private func toggleFilter() {
        let show = searchContainer.isHidden
        searchContainer.isHidden = !show
        searchHeight.constant = show ? 40 : 0
        if show {
            view.window?.makeFirstResponder(searchField)
        } else {
            searchField.stringValue = ""
            searchChanged()
        }
    }

    @objc private func addRemoteHost() {
        MenuTarget.shared.addRemoteHost()
    }

    private func setupSessionList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.width = HarnessDesign.sidebarWidth
        column.resizingMask = .autoresizingMask
        sessionTable.addTableColumn(column)
        sessionTable.headerView = nil
        sessionTable.backgroundColor = .clear
        sessionTable.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        sessionTable.rowHeight = HarnessDesign.sidebarTabRowHeight
        sessionTable.intercellSpacing = NSSize(width: 0, height: HarnessDesign.rowSpacing)
        sessionTable.selectionHighlightStyle = .none
        sessionTable.focusRingType = .none
        sessionTable.style = .plain
        sessionTable.menu = MainMenuBuilder.chromeContextMenu()
        sessionTable.dataSource = self
        sessionTable.delegate = self
        sessionTable.doubleAction = #selector(sessionDoubleClick)
        sessionTable.target = self
        sessionTable.registerForDraggedTypes([Self.sessionRowPasteboardType, Self.tabRowPasteboardType])
        sessionTable.setDraggingSourceOperationMask(.move, forLocal: false)
        sessionTable.draggingDestinationFeedbackStyle = .gap

        let scroll = NSScrollView()
        scroll.documentView = sessionTable
        scroll.menu = MainMenuBuilder.chromeContextMenu()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.automaticallyAdjustsContentInsets = false
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

    private func syncSessionColumnWidth() {
        guard let column = sessionTable.tableColumns.first else { return }
        sessionScroll?.layoutSubtreeIfNeeded()
        let width = sessionScroll?.contentView.bounds.width ?? view.bounds.width
        let clamped = max(1, width)
        // Keep the document and its single column flush with the viewport so the
        // row's equal side insets stay equal after sidebar resizing.
        if abs(sessionTable.frame.width - clamped) > 0.5 {
            sessionTable.setFrameSize(NSSize(width: clamped, height: sessionTable.frame.height))
        }
        guard abs(column.width - clamped) > 0.5 else { return }
        column.width = clamped
    }

    /// Footer: filter on the left; agents, new session, and add remote host on the right.
    /// Settings lives on ⌘, and the palette on ⌘K, so neither takes a slot here.
    private func setupFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        HarnessDesign.makeClear(footer)

        let filter = HarnessDesign.softIconButton(symbol: "line.3.horizontal.decrease.circle", tooltip: "Filter sessions")
        filter.target = self
        filter.action = #selector(toggleFilter)

        let newSession = HarnessDesign.softIconButton(symbol: "square.stack", tooltip: "New session (⇧⌘N)")
        newSession.target = self
        newSession.action = #selector(addSession)

        let remote = HarnessDesign.softIconButton(symbol: "globe", tooltip: "Add remote host…")
        remote.target = self
        remote.action = #selector(addRemoteHost)

        agentsButton.target = self
        agentsButton.action = #selector(agentsButtonClicked)

        for button in [filter, agentsButton, newSession, remote] { footer.addSubview(button) }
        view.addSubview(footer)

        let inset = HarnessDesign.Spacing.md
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: HarnessDesign.footerHeight + HarnessDesign.Spacing.sm),

            filter.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: inset),
            filter.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            remote.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -inset),
            remote.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            newSession.trailingAnchor.constraint(equalTo: remote.leadingAnchor, constant: -HarnessDesign.Spacing.sm),
            newSession.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            agentsButton.trailingAnchor.constraint(equalTo: newSession.leadingAnchor, constant: -HarnessDesign.Spacing.sm),
            agentsButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
    }

    @objc func reload() {
        let workspace = context.workspace
        workspaces = context.snapshot.workspaces
        activeWorkspaceID = workspace?.id
        activeSessionID = context.session?.id
        sessions = workspace?.sessions ?? []
        let name = workspace?.name ?? "Workspace"
        outline = SidebarOutline.lines(
            groups: SessionCoordinator.shared.sidebarGroups(),
            liveOwner: context.owner,
            live: sessions,
            activeSessionID: activeSessionID,
            query: sessionFilter,
            sessionTitle: { [weak self] in self?.displayTitle(for: $0) ?? $0.name }
        )
        workspacePill.configure(name: name, count: sessions.count)
        sessionTable.reloadData()
        if let row = outline.firstIndex(where: { if case .tab(_, _, true) = $0 { return true }; return false }) {
            sessionTable.scrollRowToVisible(row)
        }
    }

    /// Tab titles, agents, and status change often; the outline is cheap to rebuild.
    func refreshMetadata() {
        reload()
    }

    /// A named session shows its name; an unnamed one is "Session N" by position.
    private func displayTitle(for session: SessionGroup) -> String {
        SessionDisplayName.title(of: session, among: sessions)
    }

    @objc private func addWorkspace() {
        let count = SessionCoordinator.shared.snapshot.workspaces.count + 1
        SessionCoordinator.shared.addWorkspace(name: "Workspace \(count)")
    }

    /// Quick-actions menu opened from a row's ellipsis (inside the workspace
    /// dropdown). Just "Delete workspace…" — rename lives on the pill itself.
    fileprivate func confirmDeleteWorkspace(_ workspace: Workspace, anchor: NSView) {
        let menu = NSMenu()
        let delete = NSMenuItem(title: "Delete workspace…", action: #selector(deleteWorkspaceFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = workspace.id
        menu.addItem(delete)
        let point = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    /// Quick-actions menu opened from the workspace pill's ellipsis (top-level).
    /// Rename and Delete for the active workspace. Delete is disabled when this
    /// is the only workspace (you can't remove the last one).
    private func showActiveWorkspaceActions(from anchor: NSView) {
        guard let active = workspaces.first(where: { $0.id == activeWorkspaceID }) else { return }
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename workspace…", action: #selector(renameActiveWorkspace(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = active.id
        menu.addItem(rename)

        menu.addItem(.separator())

        let delete = NSMenuItem(title: "Delete workspace…", action: #selector(deleteWorkspaceFromMenu(_:)), keyEquivalent: "")
        delete.target = self
        delete.representedObject = active.id
        delete.isEnabled = workspaces.count > 1
        menu.addItem(delete)

        let point = NSPoint(x: 0, y: anchor.bounds.height + 4)
        menu.popUp(positioning: nil, at: point, in: anchor)
    }

    @objc private func renameActiveWorkspace(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WorkspaceID,
              let workspace = workspaces.first(where: { $0.id == id })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Rename workspace"
        alert.informativeText = "Enter a new name for \"\(workspace.name)\"."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.stringValue = workspace.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != workspace.name else { return }
        SessionCoordinator.shared.renameWorkspace(id: id, name: trimmed)
    }

    @objc private func deleteWorkspaceFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? WorkspaceID,
              let workspace = workspaces.first(where: { $0.id == id })
        else { return }
        dismissWorkspaceDropdown()
        let alert = NSAlert()
        alert.messageText = "Delete \"\(workspace.name)\"?"
        alert.informativeText = "All sessions and tabs in this workspace will be closed. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            SessionCoordinator.shared.closeWorkspace(id: id)
        }
    }

    @objc private func addSession() {
        guard let activeWorkspaceID else { return }
        SessionCoordinator.shared.addSession(to: activeWorkspaceID)
    }

    @objc private func sessionDoubleClick() {
        activate(row: sessionTable.clickedRow)
    }

    @objc private func showWorkspaceMenu() {
        if workspaceDropdown != nil {
            dismissWorkspaceDropdown()
            return
        }
        let dropdown = WorkspaceSwitcherPanelView(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID,
            onSelect: { [weak self] id in
                self?.dismissWorkspaceDropdown()
                SessionCoordinator.shared.selectWorkspace(id)
            },
            onNew: { [weak self] in
                self?.dismissWorkspaceDropdown()
                self?.addWorkspace()
            },
            onDelete: { [weak self] workspace, anchor in
                self?.confirmDeleteWorkspace(workspace, anchor: anchor)
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
            dropdown.heightAnchor.constraint(equalToConstant: clampedDropdownHeight(dropdown.preferredHeight)),
        ])
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : HarnessDesign.Motion.microFast
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dropdown.animator().alphaValue = 1
        }
        installWorkspaceDropdownMonitor()
    }

    private func dismissWorkspaceDropdown() {
        workspaceDropdown?.removeFromSuperview()
        workspaceDropdown = nil
        if let workspaceDropdownMonitor {
            NSEvent.removeMonitor(workspaceDropdownMonitor)
            self.workspaceDropdownMonitor = nil
        }
    }

    private func installWorkspaceDropdownMonitor() {
        if let workspaceDropdownMonitor {
            NSEvent.removeMonitor(workspaceDropdownMonitor)
        }
        workspaceDropdownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let dropdown = self.workspaceDropdown else { return event }
            guard event.window === self.view.window else {
                self.dismissWorkspaceDropdown()
                return event
            }
            let point = event.locationInWindow
            let dropdownPoint = dropdown.convert(point, from: nil)
            let pillPoint = self.workspacePill.convert(point, from: nil)
            if dropdown.bounds.contains(dropdownPoint) || self.workspacePill.bounds.contains(pillPoint) {
                return event
            }
            self.dismissWorkspaceDropdown()
            return event
        }
    }

    /// Keep the workspace dropdown on-screen: never extend past the footer. If the
    /// ideal height doesn't fit, the dropdown scrolls internally.
    private func clampedDropdownHeight(_ preferred: CGFloat) -> CGFloat {
        let available = view.bounds.height
            - HarnessDesign.tabBarHeight
            - HarnessDesign.workspaceBarHeight
            - HarnessDesign.footerHeight
            - 20
        return min(preferred, max(120, available))
    }

    @objc private func openPalette() {
        if let window = view.window {
            CommandPaletteController.present(relativeTo: window)
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.show()
    }

    private func activate(row: Int) {
        guard outline.indices.contains(row), let activeWorkspaceID else { return }
        let coordinator = SessionCoordinator.shared
        switch outline[row] {
        case .machine:
            return
        case let .session(id, _, owner, live, _):
            if live, let uuid = UUID(uuidString: id) {
                coordinator.selectSession(workspaceID: activeWorkspaceID, sessionID: uuid)
            } else {
                coordinator.focusSidebar(owner: owner, sessionID: id)
            }
        case let .tab(sessionID, tabID, _):
            guard let session = UUID(uuidString: sessionID), let tab = UUID(uuidString: tabID) else { return }
            coordinator.selectSession(workspaceID: activeWorkspaceID, sessionID: session)
            coordinator.selectTab(workspaceID: activeWorkspaceID, tabID: tab)
        }
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
        // Close by ID — selecting first and then closing "the active session" could
        // close the wrong session if the selection IPC failed or raced a snapshot change
        // while the confirmation alert was up.
        SessionCoordinator.shared.closeSession(session)
    }

    private func sessionTitle(for session: SessionGroup) -> String {
        guard let tab = session.activeTab ?? session.tabs.first else { return "Session" }
        return HarnessDesign.pathDisplayName(tab.cwd)
    }

    private enum SidebarTabAction: Int {
        case rename, close, closeOthers, splitRight, splitDown, togglePersistent
    }

    private func tabActionsMenu(for tabID: TabID) -> NSMenu? {
        guard let tab = sessions.flatMap(\.tabs).first(where: { $0.id == tabID }) else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: SidebarTabAction) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(tabActionFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = tabID
            item.tag = action.rawValue
            menu.addItem(item)
            return item
        }
        _ = add("Rename…", .rename)
        menu.addItem(.separator())
        _ = add("Split Right", .splitRight)
        _ = add("Split Down", .splitDown)
        menu.addItem(.separator())
        add("Keep Tab Running After Quit", .togglePersistent).state = tab.persistent ? .on : .off
        menu.addItem(.separator())
        _ = add("Close Tab", .close)
        _ = add("Close Other Tabs", .closeOthers)
        return menu
    }

    @objc private func tabActionFromMenu(_ sender: NSMenuItem) {
        guard let tabID = sender.representedObject as? TabID,
              let action = SidebarTabAction(rawValue: sender.tag),
              let workspaceID = activeWorkspaceID,
              let session = sessions.first(where: { $0.tabs.contains(where: { $0.id == tabID }) })
        else { return }
        let coordinator = SessionCoordinator.shared
        coordinator.selectSession(workspaceID: workspaceID, sessionID: session.id)
        coordinator.selectTab(workspaceID: workspaceID, tabID: tabID)
        // Snapshot selection must succeed before invoking actions that use the active tab.
        guard coordinator.snapshot.activeWorkspace?.activeTabID == tabID else { return }
        switch action {
        case .rename: coordinator.beginRenameActiveTab()
        case .close: coordinator.closeActiveTabWithConfirmation()
        case .closeOthers: coordinator.closeOtherTabs(keeping: tabID)
        case .splitRight: coordinator.splitTab(workspaceID: workspaceID, tabID: tabID, direction: .horizontal)
        case .splitDown: coordinator.splitTab(workspaceID: workspaceID, tabID: tabID, direction: .vertical)
        case .togglePersistent:
            guard let tab = coordinator.snapshot.activeWorkspace?.activeTab else { return }
            coordinator.requestDaemonAsync(.setTabPersistent(tabID: tabID, persistent: !tab.persistent))
        }
    }

    // MARK: - Session kebab menu

    /// Per-session actions shown on right-click of a session card (Warp-style).
    /// Items map to existing capabilities — rename via the `renameSession` IPC,
    /// close via `closeSession`, and clipboard copies handled locally. Returned for
    /// AppKit to position at the cursor (no manual `popUp`).
    private func sessionActionsMenu(for session: SessionGroup) -> NSMenu {
        let menu = NSMenu()

        let rename = NSMenuItem(title: "Rename session…", action: #selector(renameSessionFromMenu(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = session.id
        menu.addItem(rename)

        let copyCwd = NSMenuItem(title: "Copy working directory", action: #selector(copySessionCwd(_:)), keyEquivalent: "")
        copyCwd.target = self
        copyCwd.representedObject = session.id
        menu.addItem(copyCwd)

        let copyTitle = NSMenuItem(title: "Copy session title", action: #selector(copySessionTitle(_:)), keyEquivalent: "")
        copyTitle.target = self
        copyTitle.representedObject = session.id
        menu.addItem(copyTitle)

        menu.addItem(.separator())

        // Pin a session to survive a clean quit even in Plain mode (and the reverse). Always
        // offered for discoverability; the checkmark reflects the stored per-session intent. When
        // keep-on-quit is globally on, that intent is currently superseded (everything survives),
        // so the title says as much rather than hiding the control.
        let globallyKept = SessionCoordinator.shared.snapshot.keepSessionsOnQuit
        let pin = NSMenuItem(
            title: globallyKept ? "Keep running after quit (all sessions kept)" : "Keep running after quit",
            action: #selector(toggleSessionPersistent(_:)),
            keyEquivalent: ""
        )
        pin.target = self
        pin.representedObject = session.id
        pin.state = session.persistent ? .on : .off
        menu.addItem(pin)
        menu.addItem(.separator())

        let close = NSMenuItem(title: "Close session", action: #selector(closeSessionFromMenu(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = session.id
        menu.addItem(close)

        if sessions.count > 1 {
            let closeOthers = NSMenuItem(title: "Close other sessions", action: #selector(closeOtherSessionsFromMenu(_:)), keyEquivalent: "")
            closeOthers.target = self
            closeOthers.representedObject = session.id
            menu.addItem(closeOthers)
        }

        return menu
    }

    private func session(for id: SessionID) -> SessionGroup? {
        sessions.first { $0.id == id }
    }

    @objc private func renameSessionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        let current = session.name.isEmpty ? sessionTitle(for: session) : session.name
        let alert = NSAlert()
        alert.messageText = "Rename session"
        alert.informativeText = "Enter a new name for this session."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.stringValue = current
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != session.name else { return }
        SessionCoordinator.shared.requestDaemonAsync(.renameSession(sessionID: id, name: trimmed))
        SessionCoordinator.shared.refreshSnapshot()
    }

    @objc private func copySessionCwd(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id),
              let tab = session.activeTab ?? session.tabs.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tab.cwd, forType: .string)
    }

    @objc private func copySessionTitle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        let title = session.name.isEmpty ? sessionTitle(for: session) : session.name
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }

    @objc private func toggleSessionPersistent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        SessionCoordinator.shared.requestDaemonAsync(.setSessionPersistent(sessionID: id, persistent: !session.persistent))
        SessionCoordinator.shared.refreshSnapshot()
    }

    @objc private func closeSessionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let session = session(for: id) else { return }
        confirmCloseSession(session)
    }

    @objc private func closeOtherSessionsFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? SessionID, let activeWorkspaceID else { return }
        let others = sessions.filter { $0.id != id }
        guard !others.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Close \(others.count) other session\(others.count == 1 ? "" : "s")?"
        alert.informativeText = "Their tabs and running shells will be closed. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Others")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for session in others {
            // Through closeSession (not raw IPC) so each session's terminal hosts are
            // torn down too — otherwise stale TerminalHostViews linger in the registry.
            SessionCoordinator.shared.closeSession(session)
        }
        SessionCoordinator.shared.selectSession(workspaceID: activeWorkspaceID, sessionID: id)
        SessionCoordinator.shared.refreshSnapshot()
    }
}

extension HarnessSidebarPanelViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === searchField else { return }
        searchChanged()
    }
}

extension HarnessSidebarPanelViewController: NSTableViewDataSource, NSTableViewDelegate {
    fileprivate static let sessionRowPasteboardType = NSPasteboard.PasteboardType("com.robert.harness.session-row")
    /// A tab row: a tab id, droppable into any window's sidebar.
    fileprivate static let tabRowPasteboardType = NSPasteboard.PasteboardType("com.robert.harness.tab-row")

    func numberOfRows(in tableView: NSTableView) -> Int {
        outline.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch outline[row] {
        case .machine: return 26
        case .session: return HarnessDesign.sidebarSessionHeaderHeight
        case .tab: return HarnessDesign.sidebarTabRowHeight
        }
    }

    /// Index in `sessions` of the live session heading `row`, for drag-reorder.
    private func liveSessionIndex(atRow row: Int) -> Int? {
        guard outline.indices.contains(row), case let .session(id, _, _, true, _) = outline[row] else { return nil }
        return sessions.firstIndex { $0.id.uuidString == id }
    }

    /// Whether `tabID` is on this window's daemon.
    private func ownsTab(_ tabID: TabID) -> Bool {
        context.snapshot.workspaces.contains { $0.sessions.contains { $0.tabs.contains { $0.id == tabID } } }
    }

    /// The live tab at `row`.
    private func liveTab(atRow row: Int) -> (session: SessionGroup, tab: Tab)? {
        guard outline.indices.contains(row), case let .tab(sessionID, tabID, _) = outline[row],
              let session = sessions.first(where: { $0.id.uuidString == sessionID }),
              let tab = session.tabs.first(where: { $0.id.uuidString == tabID })
        else { return nil }
        return (session, tab)
    }

    /// Where a tab dropped at `row` lands: on a session heading, at its end; above a tab
    /// row, before that tab; above a heading (or past the end), at the previous session's end.
    private func tabDropTarget(row: Int, operation: NSTableView.DropOperation) -> (session: SessionGroup, index: Int)? {
        if operation == .on {
            guard let index = liveSessionIndex(atRow: row) else { return nil }
            return (sessions[index], sessions[index].tabs.count)
        }
        if let (session, tab) = liveTab(atRow: row), let index = session.tabs.firstIndex(where: { $0.id == tab.id }) {
            return (session, index)
        }
        guard let previous = (0 ..< min(row, outline.count)).reversed().lazy.compactMap(liveSessionIndex(atRow:)).first
        else { return nil }
        return (sessions[previous], sessions[previous].tabs.count)
    }

    // MARK: - Drag to reorder sessions, and tabs between sessions

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard sessionFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let item = NSPasteboardItem()
        if let index = liveSessionIndex(atRow: row) {
            item.setString(sessions[index].id.uuidString, forType: Self.sessionRowPasteboardType)
        } else if let (_, tab) = liveTab(atRow: row) {
            item.setString(tab.id.uuidString, forType: Self.tabRowPasteboardType)
        } else {
            return nil
        }
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        if let raw = info.draggingPasteboard.string(forType: Self.tabRowPasteboardType) {
            // Tabs move between sessions of one daemon, never across machines.
            guard let id = UUID(uuidString: raw), ownsTab(id) else { return [] }
            if dropOperation == .on, liveSessionIndex(atRow: row) == nil {
                tableView.setDropRow(row, dropOperation: .above)
            }
            return tabDropTarget(row: row, operation: dropOperation == .on && liveSessionIndex(atRow: row) != nil ? .on : .above) == nil ? [] : .move
        }
        // Sessions reorder within this window's list (not across workspaces or machines).
        guard dropOperation == .above, row == outline.count || liveSessionIndex(atRow: row) != nil,
              let raw = info.draggingPasteboard.string(forType: Self.sessionRowPasteboardType),
              sessions.contains(where: { $0.id.uuidString == raw })
        else { return [] }
        return .move
    }

    /// A tab row dropped outside every Harness window tears off into a window of its own.
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation.isEmpty,
              let raw = session.draggingPasteboard.string(forType: Self.tabRowPasteboardType),
              let tabID = UUID(uuidString: raw),
              !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(screenPoint) })
        else { return }
        (NSApp.delegate as? AppDelegate)?.moveTabToNewWindow(tabID, at: screenPoint)
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        if let raw = info.draggingPasteboard.string(forType: Self.tabRowPasteboardType), let tabID = UUID(uuidString: raw) {
            guard ownsTab(tabID), var target = tabDropTarget(row: row, operation: dropOperation) else { return false }
            // Within one session the index counts after the tab leaves its place.
            if let from = target.session.tabs.firstIndex(where: { $0.id == tabID }) {
                if from < target.index { target.index -= 1 }
                guard from != target.index else { return false }
            }
            SessionCoordinator.shared.moveTab(tabID, toSession: target.session.id, index: target.index)
            return true
        }
        guard let workspaceID = activeWorkspaceID,
              let item = info.draggingPasteboard.pasteboardItems?.first,
              let raw = item.string(forType: Self.sessionRowPasteboardType),
              let from = sessions.firstIndex(where: { $0.id.uuidString == raw })
        else { return false }
        // Drop gap → index among sessions: the number of session headings above it.
        let gap = (0 ..< min(row, outline.count)).filter { liveSessionIndex(atRow: $0) != nil }.count
        let target = from < gap ? gap - 1 : gap
        guard target != from else { return false }
        SessionCoordinator.shared.reorderSession(workspaceID: workspaceID, sessionID: sessions[from].id, toIndex: target)
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch outline[row] {
        case let .machine(title, detail):
            let header = SidebarGroupHeader()
            header.configure(title: title, detail: detail)
            return header
        case let .session(id, title, _, live, current):
            let header = SidebarSessionHeaderView(title: title, current: current)
            if live, let session = sessions.first(where: { $0.id.uuidString == id }) {
                header.onContextMenu = { [weak self] in self?.sessionActionsMenu(for: session) }
            }
            return header
        case let .tab(sessionID, tabID, selected):
            guard let tab = sessions.first(where: { $0.id.uuidString == sessionID })?.tabs.first(where: { $0.id.uuidString == tabID })
            else { return nil }
            let rowView = SidebarTabRowView()
            rowView.configure(tab: tab, selected: selected)
            rowView.onContextMenu = { [weak self] in self?.tabActionsMenu(for: tab.id) }
            return rowView
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammaticSelection else { return }
        let row = sessionTable.selectedRow
        activate(row: row)
        // Selection is drawn by the rows themselves; clear the table's so a repeat
        // click on the same row still fires.
        isProgrammaticSelection = true
        sessionTable.deselectAll(nil)
        isProgrammaticSelection = false
    }
}

private final class SidebarGroupHeader: NSTableCellView {
    private let title = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = HarnessDesign.chrome.textSecondary
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.horizontalInset),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, detail: String) {
        self.title.stringValue = title
        toolTip = detail.isEmpty ? nil : detail
    }
}

// MARK: - Workspace switcher

@MainActor
private final class WorkspaceSwitcherPanelView: NSView {
    private let workspaces: [Workspace]
    private let activeWorkspaceID: WorkspaceID?
    private let onSelect: (WorkspaceID) -> Void
    private let onNew: () -> Void
    private let onDelete: (Workspace, NSView) -> Void
    let preferredHeight: CGFloat

    init(
        workspaces: [Workspace],
        activeWorkspaceID: WorkspaceID?,
        onSelect: @escaping (WorkspaceID) -> Void,
        onNew: @escaping () -> Void,
        onDelete: @escaping (Workspace, NSView) -> Void
    ) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.onSelect = onSelect
        self.onNew = onNew
        self.onDelete = onDelete
        self.preferredHeight = max(84, CGFloat(37 * workspaces.count + 50))
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.cornerCurve = .continuous
        // Shadow needs to escape the bounds, so the rounded fill lives on a masked
        // sublayer instead of clipping the whole view.
        layer?.masksToBounds = false
        let c = HarnessDesign.chrome
        layer?.backgroundColor = (c.sidebarBackground.blended(withFraction: c.isDark ? 0.06 : 0.04, of: c.textPrimary) ?? c.sidebarBackground).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.11 : 0.14).cgColor
        HarnessDesign.applyShadow(.overlay, to: layer)

        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for workspace in workspaces {
            let isLast = workspaces.count == 1
            let row = WorkspaceSwitcherRow(
                title: workspace.name,
                count: workspace.sessions.count,
                isActive: workspace.id == activeWorkspaceID,
                symbol: "square.stack.3d.up",
                canDelete: !isLast
            )
            row.onClick = { [onSelect] in onSelect(workspace.id) }
            row.onMoreClick = { [weak row, onDelete] in
                guard let row else { return }
                onDelete(workspace, row)
            }
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

        // Scrollable so a long workspace list stays on-screen when the caller clamps
        // the dropdown height (see clampedDropdownHeight).
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = stack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }
}

/// A row is a plain NSView, not an NSButton: NSButton's bezel `alignmentRectInsets`
/// offset it inside the stack view, which left the selected row floating off to one
/// side. A view fills the row width cleanly and we drive the click ourselves.
@MainActor
private final class WorkspaceSwitcherRow: NSView {
    var onClick: (() -> Void)?
    var onMoreClick: (() -> Void)?

    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let moreButton = NSButton()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private let active: Bool
    private let canDelete: Bool

    init(title: String, count: Int?, isActive: Bool, symbol: String, canDelete: Bool = true) {
        active = isActive
        self.canDelete = canDelete
        // `count` retained on the init signature so call sites don't have to
        // change; the visual badge has been removed for a cleaner row.
        _ = count
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.card
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.stringValue = title
        titleLabel.font = HarnessDesign.Typography.sidebarLabel
        titleLabel.lineBreakMode = .byTruncatingTail
        HarnessDesign.prepareChromeLabel(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        toolTip = title

        // Ellipsis overflow button: shown on hover or when the row is active, so
        // the active row gets a clear "more actions" affordance without crowding
        // every row at rest.
        let moreConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")?
            .withSymbolConfiguration(moreConfig)
        moreButton.imagePosition = .imageOnly
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.isBordered = false
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.alphaValue = 0
        moreButton.isHidden = !canDelete

        addSubview(icon)
        addSubview(titleLabel)
        addSubview(moreButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -6),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            moreButton.widthAnchor.constraint(equalToConstant: 22),
            moreButton.heightAnchor.constraint(equalToConstant: 22),
        ])
        applyChrome()
    }

    @objc private func moreClicked() {
        onMoreClick?()
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

    // Capture the press (without forwarding) so this view receives the matching
    // mouseUp; the selection fires on up if the cursor is still inside the row.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { onClick?() }
    }

    private func applyChrome() {
        let c = HarnessDesign.chrome
        layer?.backgroundColor = active
            ? c.activePillFill.cgColor
            : (isHovered ? c.rowHoverFill.cgColor : NSColor.clear.cgColor)
        layer?.borderWidth = 0
        icon.contentTintColor = active ? c.accent : c.textTertiary
        titleLabel.textColor = active ? c.activePillLabel : (isHovered ? c.textPrimary : c.textSecondary)
        HarnessDesign.applyChromeLabelAppearance([titleLabel], isDark: c.isDark)
        moreButton.contentTintColor = c.textSecondary
        // Ellipsis is visible on the active row at rest and on any row when hovered.
        // Fade for polish — popping in is jarring next to the count label.
        let shouldShow = canDelete && (active || isHovered)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : HarnessDesign.Motion.microFast
            moreButton.animator().alphaValue = shouldShow ? 1 : 0
        }
    }
}

// MARK: - Workspace pill

@MainActor
final class WorkspacePillButton: NSButton {
    var onMoreClick: ((NSView) -> Void)?

    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private let moreButton = NSButton()
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

        nameLabel.font = HarnessDesign.Typography.sidebarLabel
        nameLabel.lineBreakMode = .byTruncatingTail
        HarnessDesign.prepareChromeLabel(nameLabel)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        // All header glyphs share one weight (.medium) so the icon set reads as a
        // single uniform pack rather than a mix of semibold/medium symbols.
        let chevronConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(chevronConfig)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        // Ellipsis: quick actions (rename, delete) without opening the workspace
        // dropdown first. Its own NSButton so the click is captured here instead
        // of falling through to the pill's primary action.
        let moreConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        moreButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Workspace actions")?
            .withSymbolConfiguration(moreConfig)
        moreButton.imagePosition = .imageOnly
        moreButton.bezelStyle = .accessoryBarAction
        moreButton.isBordered = false
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.target = self
        moreButton.action = #selector(moreClicked)
        moreButton.toolTip = "Workspace actions"

        addSubview(icon)
        addSubview(nameLabel)
        addSubview(moreButton)
        addSubview(chevron)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -4),
            moreButton.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -2),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 20),
            moreButton.heightAnchor.constraint(equalToConstant: 20),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 12),
        ])

        applyChrome()
    }

    @objc private func moreClicked() {
        onMoreClick?(moreButton)
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
        // `count` retained in the signature for callers that still pass it; the
        // visual badge is gone (cleaner pill) but the parameter is kept to avoid
        // a churn-y signature change at every call site.
        _ = count
        nameLabel.stringValue = name
        toolTip = name
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessDesign.chrome
        layer?.cornerRadius = HarnessDesign.Radius.card
        layer?.borderWidth = 1
        // Defined card rim (matches the session-card "side tab" look) rather than the
        // near-invisible hairline; brightens further on hover.
        layer?.borderColor = (isHovered ? c.focusRing.withAlphaComponent(c.isDark ? 0.45 : 0.50) : c.borderStrong).cgColor
        let resting = c.surfaceElevated
        let hover = c.textPrimary.withAlphaComponent(c.isDark ? 0.11 : 0.12)
        layer?.backgroundColor = (isHovered ? hover : resting).cgColor
        // Resting color matches the search placeholder (textSecondary); brightens to
        // primary on hover — same resting/active rule used by every other label.
        nameLabel.textColor = isHovered ? c.textPrimary : c.textSecondary
        HarnessDesign.applyChromeLabelAppearance([nameLabel], isDark: c.isDark)
        icon.contentTintColor = isHovered ? c.textPrimary : c.textSecondary
        chevron.contentTintColor = isHovered ? c.textSecondary : c.textTertiary
        moreButton.contentTintColor = isHovered ? c.textSecondary : c.textTertiary
    }
}

// MARK: - Session card

/// Session heading in the sidebar: the session's name over its tabs. Right-click for
/// rename, copy, keep-running, and close.
@MainActor
final class SidebarSessionHeaderView: NSView {
    var onContextMenu: (() -> NSMenu?)?
    private let label = NSTextField(labelWithString: "")

    init(title: String, current: Bool) {
        super.init(frame: .zero)
        let c = HarnessChrome.current
        label.stringValue = title
        label.font = HarnessDesign.Typography.sidebarLabel
        label.textColor = current ? c.textPrimary : c.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.Spacing.xl),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -HarnessDesign.Spacing.md),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -HarnessDesign.Spacing.sm),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(current ? "\(title), current session" : "Session \(title)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }
}

/// A tab under its session heading: app tile, identity, and status, with the selected
/// tab as a filled pill (the same fill as the active title-bar tab).
@MainActor
final class SidebarTabRowView: NSView {
    var onContextMenu: (() -> NSMenu?)?
    private let moreButton = SoftIconButton(frame: .zero)
    private let fill = NSView()
    private let tile = IconTileView(size: HarnessDesign.tabIconTileSize)
    private var glassView: NSView?
    private let label = NSTextField(labelWithString: "")
    private let status = TabStatusView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
    private var selected = false
    private var hovered = false { didSet { applyColors() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        fill.wantsLayer = true
        fill.layer?.cornerRadius = HarnessDesign.tabPillHeight / 2
        fill.layer?.cornerCurve = .continuous
        if let glass = HarnessDesign.makeLiquidGlass(cornerRadius: HarnessDesign.tabPillHeight / 2) {
            glass.translatesAutoresizingMaskIntoConstraints = false
            fill.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: fill.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: fill.trailingAnchor),
                glass.topAnchor.constraint(equalTo: fill.topAnchor),
                glass.bottomAnchor.constraint(equalTo: fill.bottomAnchor),
            ])
            glassView = glass
        }
        label.font = HarnessDesign.Typography.tabTitle
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        moreButton.style = .plainGlyph
        moreButton.setSymbol("ellipsis", accessibilityDescription: "Tab actions", pointSize: 13, weight: .medium)
        moreButton.toolTip = "Tab actions"
        moreButton.target = self
        moreButton.action = #selector(showActions)
        moreButton.isHidden = true
        for view in [fill, tile, label, status, moreButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let side = HarnessDesign.Spacing.md
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: side),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -side),
            fill.centerYAnchor.constraint(equalTo: centerYAnchor),
            fill.heightAnchor.constraint(equalToConstant: HarnessDesign.tabPillHeight),
            tile.leadingAnchor.constraint(equalTo: fill.leadingAnchor, constant: HarnessDesign.tabIconTileInset),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: HarnessDesign.Spacing.md),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -HarnessDesign.Spacing.sm),
            status.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -HarnessDesign.Spacing.md),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 12),
            status.heightAnchor.constraint(equalToConstant: 12),
            moreButton.trailingAnchor.constraint(equalTo: fill.trailingAnchor, constant: -HarnessDesign.Spacing.xs),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(tab: Tab, selected: Bool) {
        self.selected = selected
        let base = SurfaceIdentity.label(directory: tab.cwd, program: tab.currentCommand, agent: tab.agent?.kind.commandToken)
        label.stringValue = TabChip.title(base: base, app: tab.programMark?.app)
        tile.apply(IconTileView.content(for: tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title)))
        let activity = TabActivity.of(tab)
        status.apply(selected && (activity == .working || activity == .done) ? .none : activity,
                     tint: HarnessChrome.current.accent, progress: TabActivity.progress(of: tab))
        var parts = [label.stringValue]
        if let state = TabStatusView.label(activity) { parts.append(state) }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(parts.joined(separator: ", "))
        setAccessibilitySelected(selected)
        applyColors()
    }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?() }

    @objc private func showActions() {
        guard let menu = onContextMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: moreButton.bounds.maxX, y: moreButton.bounds.minY), in: moreButton)
        if let window {
            hovered = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    private func applyColors() {
        let c = HarnessChrome.current
        glassView?.isHidden = !selected
        if selected, let glass = glassView {
            HarnessDesign.setLiquidGlassTint(HarnessDesign.activeTabGlassTint, on: glass)
            fill.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            fill.layer?.backgroundColor = selected ? HarnessDesign.activeTabFill.cgColor
                : (hovered ? c.rowHoverFill.cgColor : NSColor.clear.cgColor)
        }
        HarnessDesign.applyShadow(selected && c.isDark ? .elevation1 : .none, to: fill.layer)
        fill.layer?.borderWidth = selected ? 1 : 0
        fill.layer?.borderColor = c.textPrimary.withAlphaComponent(HarnessDesign.activeGlassBorderAlpha(isDark: c.isDark)).cgColor
        label.textColor = selected ? c.activePillLabel : (hovered ? c.textPrimary : c.textSecondary)
        tile.applyChrome()
        moreButton.applyChrome()
        moreButton.isHidden = !hovered
        status.isHidden = hovered || status.activity == .none
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        if let window {
            hovered = NSApp.isActive && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}
