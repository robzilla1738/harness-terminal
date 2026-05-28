import AppKit
import HarnessCore
import HarnessTerminalKit

@MainActor
struct PaletteAction: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
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

    static func present(relativeTo parent: NSWindow?) {
        panel?.close()
        let controller = PaletteViewController(actions: buildActions())
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
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
                y: f.midY - panel.frame.height / 2 + f.height * 0.12
            ))
        } else {
            panel.center()
        }
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        controller.focusSearch()
    }

    private static func buildActions() -> [PaletteAction] {
        let coordinator = SessionCoordinator.shared
        return [
            PaletteAction(title: "New Workspace", subtitle: "⇧⌘N") {
                coordinator.addWorkspace(name: "Workspace \(coordinator.snapshot.workspaces.count + 1)")
            },
            PaletteAction(title: "New Session", subtitle: "Sidebar") {
                if let id = coordinator.snapshot.activeWorkspaceID {
                    coordinator.addSession(to: id)
                }
            },
            PaletteAction(title: "New Tab", subtitle: "⌘T") {
                if let id = coordinator.snapshot.activeWorkspaceID {
                    coordinator.addTab(to: id)
                }
            },
            PaletteAction(title: "Split Horizontal", subtitle: "⌘D") {
                coordinator.splitActivePane(direction: .horizontal)
            },
            PaletteAction(title: "Split Vertical", subtitle: "⇧⌘D") {
                coordinator.splitActivePane(direction: .vertical)
            },
            PaletteAction(title: "Jump to Notification", subtitle: "⇧⌘U") {
                coordinator.jumpToLatestNotification()
            },
            PaletteAction(title: "Install harness-cli to PATH", subtitle: "Copy to Application Support") {
                CLIInstaller.install()
            },
            PaletteAction(title: "Open Settings", subtitle: "⌘,") {
                SettingsWindowController.show()
            },
        ] + ThemeManager.featuredThemes.map { theme in
            PaletteAction(title: "Theme: \(theme)", subtitle: "Appearance") {
                coordinator.setTheme(theme, clearColorOverrides: true)
            }
        }
    }
}

@MainActor
final class PaletteViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate, NSWindowDelegate
{
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let allActions: [PaletteAction]
    private var filtered: [PaletteAction] = []

    init(actions: [PaletteAction]) {
        allActions = actions
        filtered = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let overlay = HarnessOverlayBackground()
        overlay.frame = NSRect(x: 0, y: 0, width: 560, height: 380)
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
            string: "Search commands…",
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
        tableView.rowHeight = 40
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

        content.addSubview(magnifier)
        content.addSubview(searchField)
        content.addSubview(separator)
        content.addSubview(scrollView)

        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HarnessDesign.Spacing.xl),
            magnifier.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 18),

            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: HarnessDesign.Spacing.lg),
            searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: HarnessDesign.Spacing.sm),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            searchField.heightAnchor.constraint(equalToConstant: 26),

            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: HarnessDesign.Spacing.sm),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -HarnessDesign.Spacing.sm),
        ])

        tableView.reloadData()
        selectRow(0)
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Filtering

    func controlTextDidChange(_ obj: Notification) {
        let query = searchField.stringValue.lowercased()
        if query.isEmpty {
            filtered = allActions
        } else {
            filtered = allActions.filter {
                $0.title.lowercased().contains(query) || $0.subtitle.lowercased().contains(query)
            }
        }
        tableView.reloadData()
        selectRow(0)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            selectRow(tableView.selectedRow + 1); return true
        case #selector(NSResponder.moveUp(_:)):
            selectRow(tableView.selectedRow - 1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activate(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            view.window?.close(); return true
        default:
            return false
        }
    }

    private func selectRow(_ index: Int) {
        guard !filtered.isEmpty else { return }
        let clamped = max(0, min(index, filtered.count - 1))
        tableView.selectRowIndexes([clamped], byExtendingSelection: false)
        tableView.scrollRowToVisible(clamped)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = filtered[row]
        let c = HarnessChrome.current

        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = c.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail

        let shortcut = NSTextField(labelWithString: action.subtitle)
        shortcut.font = HarnessDesign.Typography.kbd
        shortcut.textColor = c.textTertiary
        shortcut.alignment = .right
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.setContentHuggingPriority(.required, for: .horizontal)
        shortcut.setContentCompressionResistancePriority(.required, for: .horizontal)

        let cell = NSView()
        cell.addSubview(title)
        cell.addSubview(shortcut)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: HarnessDesign.Spacing.xl),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -HarnessDesign.Spacing.sm),
        ])
        return cell
    }

    @objc private func activate() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let action = filtered[row]
        view.window?.close()
        action.handler()
    }

    // MARK: - Dismiss on focus loss

    func windowDidResignKey(_ notification: Notification) {
        view.window?.close()
    }
}

/// Table row that draws the themed selection fill instead of the system blue.
@MainActor
final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: HarnessDesign.Spacing.sm, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: HarnessDesign.Radius.control, yRadius: HarnessDesign.Radius.control)
        HarnessChrome.current.rowSelectedFill.setFill()
        path.fill()
    }
}
