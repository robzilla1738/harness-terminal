import AppKit
import HarnessCore
import HarnessTerminalKit

/// One row in the palette — title + subtitle + SF Symbol + optional shortcut +
/// section. Sections are surfaced as a tinted header above their first row.
@MainActor
struct PaletteAction: Identifiable {
    enum Section: Int, CaseIterable {
        case recent, actions, navigation, workspaces, tabs, themes

        var title: String {
            switch self {
            case .recent: return "Recent"
            case .actions: return "Actions"
            case .navigation: return "Navigation"
            case .workspaces: return "Workspaces"
            case .tabs: return "Tabs"
            case .themes: return "Themes"
            }
        }
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let shortcut: String
    let section: Section
    let handler: () -> Void
}

/// Borderless panel that can still take key focus (needed for the search field).
@MainActor
private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
enum CommandPaletteController {
    private static var panel: NSPanel?
    /// MRU stack of action IDs the user has just run. Persisted across launches so
    /// the palette feels like it learns from the user.
    private static let recentDefaultsKey = "com.robert.harness.palette.recent"
    private static let recentLimit = 5

    static func present(relativeTo parent: NSWindow?) {
        panel?.close()
        let controller = PaletteViewController(actions: buildActions(), recentIDs: loadRecents())
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isRestorable = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentViewController = controller
        panel.delegate = controller

        // Centered over the parent's upper third — Spotlight-style placement.
        if let parent {
            let f = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: f.midX - panel.frame.width / 2,
                y: f.midY - panel.frame.height / 2 + f.height * 0.14
            ))
        } else {
            panel.center()
        }
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.spring) { _ in
            panel.animator().alphaValue = 1
        }
        controller.focusSearch()
    }

    static func recordUsage(_ actionID: String) {
        var current = loadRecents()
        current.removeAll { $0 == actionID }
        current.insert(actionID, at: 0)
        if current.count > recentLimit { current = Array(current.prefix(recentLimit)) }
        UserDefaults.standard.set(current, forKey: recentDefaultsKey)
    }

    private static func loadRecents() -> [String] {
        UserDefaults.standard.stringArray(forKey: recentDefaultsKey) ?? []
    }

    private static func buildActions() -> [PaletteAction] {
        let coordinator = SessionCoordinator.shared
        let snapshot = coordinator.snapshot

        var actions: [PaletteAction] = []

        // MARK: - Actions
        actions.append(contentsOf: [
            PaletteAction(
                id: "action.newWorkspace",
                title: "New Workspace",
                subtitle: "Create a fresh workspace",
                symbol: "rectangle.stack.badge.plus",
                shortcut: "⇧⌘N",
                section: .actions
            ) {
                coordinator.addWorkspace(name: "Workspace \(coordinator.snapshot.workspaces.count + 1)")
            },
            PaletteAction(
                id: "action.newSession",
                title: "New Session",
                subtitle: "Add a sidebar session row",
                symbol: "square.split.bottomrightquarter",
                shortcut: "",
                section: .actions
            ) {
                if let id = coordinator.snapshot.activeWorkspaceID {
                    coordinator.addSession(to: id)
                }
            },
            PaletteAction(
                id: "action.newTab",
                title: "New Tab",
                subtitle: "Open a new shell in the active session",
                symbol: "plus.rectangle.on.rectangle",
                shortcut: "⌘T",
                section: .actions
            ) {
                if let id = coordinator.snapshot.activeWorkspaceID {
                    coordinator.addTab(to: id)
                }
            },
            PaletteAction(
                id: "action.splitH",
                title: "Split Horizontal",
                subtitle: "Split the active pane to the right",
                symbol: "rectangle.split.2x1",
                shortcut: "⌘D",
                section: .actions
            ) {
                coordinator.splitActivePane(direction: .horizontal)
            },
            PaletteAction(
                id: "action.splitV",
                title: "Split Vertical",
                subtitle: "Split the active pane downward",
                symbol: "rectangle.split.1x2",
                shortcut: "⇧⌘D",
                section: .actions
            ) {
                coordinator.splitActivePane(direction: .vertical)
            },
            PaletteAction(
                id: "action.zoomPane",
                title: "Zoom Pane",
                subtitle: "Toggle tmux-style zoom on the active pane",
                symbol: "arrow.up.left.and.arrow.down.right",
                shortcut: "Prefix z",
                section: .actions
            ) {
                coordinator.zoomActivePane()
            },
            PaletteAction(
                id: "action.killPane",
                title: "Kill Pane",
                subtitle: "Close the active pane and its shell",
                symbol: "xmark.square",
                shortcut: "Prefix x",
                section: .actions
            ) {
                coordinator.killActivePane()
            },
            PaletteAction(
                id: "action.copyMode",
                title: "Toggle Copy Mode",
                subtitle: "Enter scrollback / selection mode",
                symbol: "doc.on.clipboard",
                shortcut: "Prefix [",
                section: .actions
            ) {
                coordinator.toggleCopyMode()
            },
            PaletteAction(
                id: "action.renameTab",
                title: "Rename Active Tab",
                subtitle: "Set a custom title for the current tab",
                symbol: "pencil",
                shortcut: "Prefix ,",
                section: .actions
            ) {
                coordinator.beginRenameActiveTab()
            },
            PaletteAction(
                id: "action.installCLI",
                title: "Install harness-cli to PATH",
                subtitle: "Copy the CLI to Application Support",
                symbol: "arrow.down.app",
                shortcut: "",
                section: .actions
            ) {
                CLIInstaller.install()
            },
            PaletteAction(
                id: "action.settings",
                title: "Open Settings",
                subtitle: "Theme, font, agents, key bindings",
                symbol: "gearshape",
                shortcut: "⌘,",
                section: .actions
            ) {
                SettingsWindowController.show()
            },
            PaletteAction(
                id: "action.reimport",
                title: "Re-import from Ghostty",
                subtitle: "Refresh theme + colors from ~/.config/ghostty",
                symbol: "arrow.triangle.2.circlepath",
                shortcut: "Prefix r",
                section: .actions
            ) {
                coordinator.reimportFromGhostty()
            },
        ])

        // MARK: - Navigation
        actions.append(contentsOf: [
            PaletteAction(
                id: "nav.jumpNotification",
                title: "Jump to Notification",
                subtitle: "Focus the next tab waiting on input",
                symbol: "bell.badge",
                shortcut: "⇧⌘U",
                section: .navigation
            ) {
                coordinator.jumpToLatestNotification()
            },
            PaletteAction(
                id: "nav.prevTab",
                title: "Previous Tab",
                subtitle: "Cycle to the previous tab",
                symbol: "chevron.left.square",
                shortcut: "⇧⌘[",
                section: .navigation
            ) {
                coordinator.selectAdjacentTab(offset: -1)
            },
            PaletteAction(
                id: "nav.nextTab",
                title: "Next Tab",
                subtitle: "Cycle to the next tab",
                symbol: "chevron.right.square",
                shortcut: "⇧⌘]",
                section: .navigation
            ) {
                coordinator.selectAdjacentTab(offset: 1)
            },
            PaletteAction(
                id: "nav.cyclePane",
                title: "Cycle Pane",
                subtitle: "Move focus to the next pane in the tab",
                symbol: "rectangle.3.group",
                shortcut: "Prefix o",
                section: .navigation
            ) {
                coordinator.cycleActivePane(forward: true)
            },
        ])

        // MARK: - Workspaces
        for (idx, workspace) in snapshot.workspaces.enumerated() {
            let isActive = workspace.id == snapshot.activeWorkspaceID
            actions.append(PaletteAction(
                id: "workspace.\(workspace.id.uuidString)",
                title: workspace.name,
                subtitle: workspaceSubtitle(workspace, isActive: isActive),
                symbol: isActive ? "checkmark.rectangle.stack.fill" : "rectangle.stack",
                shortcut: idx < 9 ? "⌘\(idx + 1)" : "",
                section: .workspaces
            ) {
                coordinator.selectWorkspace(workspace.id)
            })
        }

        // MARK: - Tabs in active workspace
        if let workspace = snapshot.activeWorkspace {
            for tab in workspace.tabs {
                let folder = HarnessDesign.pathDisplayName(tab.cwd)
                let title = !folder.isEmpty ? folder : (tab.title.isEmpty ? "Terminal" : tab.title)
                let subtitle = HarnessDesign.shortenPath(tab.cwd)
                actions.append(PaletteAction(
                    id: "tab.\(tab.id.uuidString)",
                    title: title,
                    subtitle: subtitle,
                    symbol: tab.status == .waiting ? "bell.fill" : (tab.agent != nil ? "sparkles" : "terminal"),
                    shortcut: "",
                    section: .tabs
                ) {
                    coordinator.selectTab(workspaceID: workspace.id, tabID: tab.id)
                })
            }
        }

        // MARK: - Themes (featured first)
        for theme in ThemeManager.featuredThemes {
            actions.append(PaletteAction(
                id: "theme.\(theme)",
                title: theme,
                subtitle: "Apply Ghostty theme",
                symbol: "paintpalette",
                shortcut: "",
                section: .themes
            ) {
                coordinator.setTheme(theme, clearColorOverrides: true)
            })
        }

        return actions
    }

    private static func workspaceSubtitle(_ workspace: Workspace, isActive: Bool) -> String {
        let sessions = workspace.sessions.count
        let tabs = workspace.sessions.reduce(0) { $0 + $1.tabs.count }
        let prefix = isActive ? "Active · " : ""
        return prefix + "\(sessions) session\(sessions == 1 ? "" : "s") · \(tabs) tab\(tabs == 1 ? "" : "s")"
    }
}

// MARK: - Fuzzy match

@MainActor
private enum FuzzyMatcher {
    /// Score `string` against `query`. Returns nil when no subsequence match.
    /// Higher scores rank earlier:
    ///   • +60 prefix match
    ///   • +20 word-start match per char (after space / `.`/`-`/`_`)
    ///   • +6  consecutive match
    ///   • +3  base per matched character
    ///   • +1  exact-case match per char
    ///   • -1  per char skipped between matches (gap penalty)
    static func score(query: String, in string: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let lowerQ = Array(query.lowercased())
        let lowerS = Array(string.lowercased())
        let originalS = Array(string)
        let originalQ = Array(query)

        var score = 0
        var sIdx = 0
        var lastMatch = -1
        for (qIdx, q) in lowerQ.enumerated() {
            var matched = false
            while sIdx < lowerS.count {
                if lowerS[sIdx] == q {
                    score += 3
                    if originalS[sIdx] == originalQ[qIdx] { score += 1 }
                    if sIdx == 0 || isWordStart(lowerS, at: sIdx) { score += 20 }
                    if lastMatch >= 0 && sIdx == lastMatch + 1 { score += 6 }
                    let gap = sIdx - (lastMatch + 1)
                    if gap > 0 { score -= gap }
                    lastMatch = sIdx
                    sIdx += 1
                    matched = true
                    break
                }
                sIdx += 1
            }
            if !matched { return nil }
        }
        if lowerS.starts(with: lowerQ) { score += 60 }
        return score
    }

    private static func isWordStart(_ chars: [Character], at idx: Int) -> Bool {
        guard idx > 0 else { return true }
        switch chars[idx - 1] {
        case " ", ".", "-", "_", "/", ":": return true
        default: return false
        }
    }
}

// MARK: - View controller

@MainActor
final class PaletteViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSWindowDelegate
{
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No matching commands")
    private let footer = NSView()
    private let allActions: [PaletteAction]
    private let recentIDs: [String]
    /// Flat list of rows shown — alternating section headers and items.
    private var rows: [Row] = []
    /// Logical positions of actionable rows so arrow-keys skip headers.
    private var selectableRowIndexes: [Int] = []

    private enum Row {
        case header(PaletteAction.Section)
        case item(PaletteAction)
    }

    init(actions: [PaletteAction], recentIDs: [String]) {
        allActions = actions
        self.recentIDs = recentIDs
        super.init(nibName: nil, bundle: nil)
        rebuildRows(query: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let overlay = HarnessOverlayBackground()
        overlay.frame = NSRect(x: 0, y: 0, width: 620, height: 440)
        view = overlay
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let c = HarnessChrome.current
        guard let content = (view as? HarnessOverlayBackground)?.contentView else { return }

        let magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        magnifier.contentTintColor = c.textTertiary
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderAttributedString = NSAttributedString(
            string: "Search commands, workspaces, themes…",
            attributes: [.foregroundColor: c.textTertiary, .font: NSFont.systemFont(ofSize: 15)]
        )
        searchField.font = .systemFont(ofSize: 15)
        searchField.textColor = c.textPrimary
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = c.border.cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("action"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none // PaletteRowView draws themed selection
        tableView.doubleAction = #selector(activate)
        tableView.target = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = c.textTertiary
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true

        footer.wantsLayer = true
        footer.layer?.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.04 : 0.05).cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        let footerHint = makeFooterHint()
        footer.addSubview(footerHint)
        NSLayoutConstraint.activate([
            footerHint.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: HarnessDesign.Spacing.xl),
            footerHint.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            footerHint.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        content.addSubview(magnifier)
        content.addSubview(searchField)
        content.addSubview(separator)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HarnessDesign.Spacing.xl + 2),
            magnifier.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 18),

            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: HarnessDesign.Spacing.lg + 2),
            searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: HarnessDesign.Spacing.md),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: HarnessDesign.Spacing.lg),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),
        ])

        tableView.reloadData()
        selectFirstSelectable()
    }

    private func makeFooterHint() -> NSView {
        let c = HarnessChrome.current
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = HarnessDesign.Spacing.lg
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        func chip(_ keys: String, label: String) -> NSView {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 4
            row.alignment = .centerY

            let kbd = NSTextField(labelWithString: keys)
            kbd.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            kbd.textColor = c.textSecondary
            kbd.drawsBackground = true
            kbd.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.08 : 0.10)
            kbd.isBezeled = false
            kbd.wantsLayer = true
            kbd.layer?.cornerRadius = 3
            kbd.layer?.cornerCurve = .continuous
            kbd.alignment = .center
            // The bezelless field renders without padding by default; give it a
            // little horizontal breathing room via a wrapping view.
            let wrap = NSView()
            wrap.wantsLayer = true
            wrap.layer?.cornerRadius = 3
            wrap.layer?.cornerCurve = .continuous
            wrap.layer?.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.08 : 0.10).cgColor
            kbd.drawsBackground = false
            kbd.translatesAutoresizingMaskIntoConstraints = false
            wrap.addSubview(kbd)
            NSLayoutConstraint.activate([
                kbd.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 5),
                kbd.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -5),
                kbd.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 1),
                kbd.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -1),
            ])
            row.addArrangedSubview(wrap)

            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 11, weight: .regular)
            text.textColor = c.textTertiary
            row.addArrangedSubview(text)
            return row
        }
        stack.addArrangedSubview(chip("↑↓", label: "Navigate"))
        stack.addArrangedSubview(chip("↩", label: "Run"))
        stack.addArrangedSubview(chip("esc", label: "Close"))
        return stack
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Filtering / ranking

    func controlTextDidChange(_ obj: Notification) {
        rebuildRows(query: searchField.stringValue)
        tableView.reloadData()
        emptyLabel.isHidden = !selectableRowIndexes.isEmpty
        selectFirstSelectable()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activate(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            view.window?.close(); return true
        default:
            return false
        }
    }

    private func rebuildRows(query rawQuery: String) {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        var matches: [(action: PaletteAction, score: Int)] = []

        if query.isEmpty {
            // Empty query: prepend recents (filtered against currently-available
            // actions so stale IDs don't appear), then everything in section order.
            let recents = recentIDs.compactMap { id in allActions.first(where: { $0.id == id }) }
            for action in recents {
                matches.append((action: PaletteAction(
                    id: action.id,
                    title: action.title,
                    subtitle: action.subtitle,
                    symbol: action.symbol,
                    shortcut: action.shortcut,
                    section: .recent,
                    handler: action.handler
                ), score: 0))
            }
            let recentIDSet = Set(recents.map(\.id))
            for action in allActions where !recentIDSet.contains(action.id) {
                matches.append((action, 0))
            }
        } else {
            for action in allActions {
                let titleScore = FuzzyMatcher.score(query: query, in: action.title) ?? -1
                let subtitleScore = FuzzyMatcher.score(query: query, in: action.subtitle) ?? -1
                let best = max(titleScore, subtitleScore >= 0 ? subtitleScore - 5 : -1)
                if best >= 0 {
                    // Boost recents so a query that matches multiple things prefers a
                    // command the user actually uses.
                    let recencyBoost = recentIDs.firstIndex(of: action.id).map { 15 - $0 } ?? 0
                    matches.append((action, best + recencyBoost))
                }
            }
            matches.sort { $0.score > $1.score }
        }

        // Group into ordered sections with header rows.
        var newRows: [Row] = []
        var selectable: [Int] = []
        if query.isEmpty {
            // Empty: keep section order natural — recent first, then everything else.
            let sectionsInOrder: [PaletteAction.Section] = [.recent, .actions, .navigation, .workspaces, .tabs, .themes]
            for section in sectionsInOrder {
                let entries = matches.filter { $0.action.section == section }
                if entries.isEmpty { continue }
                newRows.append(.header(section))
                for entry in entries {
                    selectable.append(newRows.count)
                    newRows.append(.item(entry.action))
                }
            }
        } else {
            // Search mode: top results first regardless of section, but still group
            // by section to give the user a sense of *what kind* of thing matched.
            var bySection: [PaletteAction.Section: [(PaletteAction, Int)]] = [:]
            for entry in matches {
                bySection[entry.action.section, default: []].append((entry.action, entry.score))
            }
            let sectionsInOrder = PaletteAction.Section.allCases.sorted { a, b in
                let aBest = bySection[a]?.first?.1 ?? 0
                let bBest = bySection[b]?.first?.1 ?? 0
                return aBest > bBest
            }
            for section in sectionsInOrder {
                guard let entries = bySection[section], !entries.isEmpty else { continue }
                newRows.append(.header(section))
                for entry in entries {
                    selectable.append(newRows.count)
                    newRows.append(.item(entry.0))
                }
            }
        }

        rows = newRows
        selectableRowIndexes = selectable
    }

    private func selectFirstSelectable() {
        guard let first = selectableRowIndexes.first else { return }
        tableView.selectRowIndexes([first], byExtendingSelection: false)
        tableView.scrollRowToVisible(first)
    }

    private func moveSelection(by offset: Int) {
        guard !selectableRowIndexes.isEmpty else { return }
        let current = tableView.selectedRow
        let pos = selectableRowIndexes.firstIndex(of: current) ?? 0
        let target = (pos + offset + selectableRowIndexes.count) % selectableRowIndexes.count
        let row = selectableRowIndexes[target]
        tableView.selectRowIndexes([row], byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 26
        case .item: return 48
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(section):
            return PaletteSectionHeaderView(title: section.title.uppercased())
        case let .item(action):
            return PaletteItemView(action: action, query: searchField.stringValue)
        }
    }

    @objc private func activate() {
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        guard case let .item(action) = rows[row] else { return }
        CommandPaletteController.recordUsage(action.id)
        view.window?.close()
        action.handler()
    }

    // MARK: - Dismiss on focus loss

    func windowDidResignKey(_ notification: Notification) {
        view.window?.close()
    }
}

// MARK: - Row views

/// Table row that draws the themed selection fill instead of the system blue.
@MainActor
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: HarnessDesign.Spacing.md, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: HarnessDesign.Radius.control, yRadius: HarnessDesign.Radius.control)
        let c = HarnessChrome.current
        c.accent.withAlphaComponent(c.isDark ? 0.16 : 0.13).setFill()
        path.fill()
    }
}

@MainActor
private final class PaletteSectionHeaderView: NSView {
    init(title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = HarnessDesign.Typography.paletteHeader
        label.textColor = HarnessChrome.current.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.Spacing.xl),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class PaletteItemView: NSView {
    init(action: PaletteAction, query: String) {
        super.init(frame: .zero)
        let c = HarnessChrome.current

        let iconBackground = NSView()
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = HarnessDesign.Radius.control
        iconBackground.layer?.cornerCurve = .continuous
        iconBackground.layer?.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.06 : 0.07).cgColor
        iconBackground.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        icon.contentTintColor = c.textSecondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(icon)

        let title = NSTextField(labelWithString: action.title)
        title.font = HarnessDesign.Typography.paletteTitle
        title.textColor = c.textPrimary
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        if !query.isEmpty {
            title.attributedStringValue = highlight(title.stringValue, query: query, primary: c.textPrimary, accent: c.accent)
        }

        let subtitle = NSTextField(labelWithString: action.subtitle)
        subtitle.font = .systemFont(ofSize: 11.5, weight: .regular)
        subtitle.textColor = c.textTertiary
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let shortcut = NSTextField(labelWithString: action.shortcut)
        shortcut.font = HarnessDesign.Typography.kbd
        shortcut.textColor = c.textTertiary
        shortcut.alignment = .right
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcut.isHidden = action.shortcut.isEmpty

        addSubview(iconBackground)
        addSubview(title)
        addSubview(subtitle)
        addSubview(shortcut)

        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HarnessDesign.Spacing.xl),
            iconBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 30),
            iconBackground.heightAnchor.constraint(equalToConstant: 30),

            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: HarnessDesign.Spacing.lg),
            title.topAnchor.constraint(equalTo: iconBackground.topAnchor, constant: -1),
            title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -HarnessDesign.Spacing.md),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -HarnessDesign.Spacing.md),

            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            shortcut.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Bold the characters in `title` that matched the user's query — gives the
    /// fuzzy match a visual anchor without resorting to a full word-by-word render.
    private func highlight(_ title: String, query: String, primary: NSColor, accent: NSColor) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: HarnessDesign.Typography.paletteTitle,
            .foregroundColor: primary,
        ]
        let result = NSMutableAttributedString(string: title, attributes: attrs)
        let lowerTitle = title.lowercased()
        let lowerQuery = query.lowercased()
        var titleIdx = lowerTitle.startIndex
        for q in lowerQuery {
            guard titleIdx < lowerTitle.endIndex else { break }
            if let found = lowerTitle[titleIdx...].firstIndex(of: q) {
                let nsRange = NSRange(found ... found, in: title)
                result.addAttributes([
                    .foregroundColor: accent,
                    .font: NSFont.systemFont(ofSize: 13.5, weight: .heavy),
                ], range: nsRange)
                titleIdx = lowerTitle.index(after: found)
            }
        }
        return result
    }
}
