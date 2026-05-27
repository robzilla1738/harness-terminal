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

@MainActor
enum CommandPaletteController {
    private static var panel: NSPanel?

    static func present(relativeTo parent: NSWindow?) {
        let actions = buildActions()
        let controller = PaletteViewController(actions: actions)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.nonactivatingPanel, .titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Command Palette"
        panel.contentViewController = controller
        panel.isFloatingPanel = true
        panel.level = .floating
        if parent != nil {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func buildActions() -> [PaletteAction] {
        let coordinator = SessionCoordinator.shared
        return [
            PaletteAction(title: "New Workspace", subtitle: "Cmd+Shift+N") {
                coordinator.addWorkspace(name: "Workspace \(coordinator.snapshot.workspaces.count + 1)")
            },
            PaletteAction(title: "New Session", subtitle: "Sidebar") {
                if let id = coordinator.snapshot.activeWorkspaceID {
                    coordinator.addSession(to: id)
                }
            },
            PaletteAction(title: "New Tab", subtitle: "Cmd+T") {
                if let id = coordinator.snapshot.activeWorkspaceID {
                    coordinator.addTab(to: id)
                }
            },
            PaletteAction(title: "Split Horizontal", subtitle: "Cmd+D") {
                coordinator.splitActivePane(direction: .horizontal)
            },
            PaletteAction(title: "Split Vertical", subtitle: "Cmd+Shift+D") {
                coordinator.splitActivePane(direction: .vertical)
            },
            PaletteAction(title: "Jump to Notification", subtitle: "Cmd+Shift+U") {
                coordinator.jumpToLatestNotification()
            },
            PaletteAction(title: "Install harness-cli to PATH", subtitle: "Copy to Application Support") {
                CLIInstaller.install()
            },
            PaletteAction(title: "Open Settings", subtitle: "Cmd+,") {
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
final class PaletteViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let allActions: [PaletteAction]
    private var filtered: [PaletteAction] = []

    init(actions: [PaletteAction]) {
        allActions = actions
        filtered = actions
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        searchField.placeholderString = "Search commands…"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: .init("action"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 44
        tableView.doubleAction = #selector(activate)
        tableView.target = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchField)
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tableView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

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
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filtered.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = filtered[row]
        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let subtitle = NSTextField(labelWithString: action.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.spacing = 2
        return stack
    }

    @objc private func activate() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        filtered[row].handler()
        view.window?.close()
    }
}
