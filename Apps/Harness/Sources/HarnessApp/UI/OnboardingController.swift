import AppKit
import HarnessCore

/// First-run onboarding: a paged walkthrough of Harness's multiplexer model
/// (prefix key, panes, tabs/sessions/workspaces, attach-anywhere, agents) plus a
/// live keyboard-shortcut guide generated from the real prefix `KeyTable`.
///
/// Shown once (tracked in `UserDefaults`); re-openable any time from
/// **Help → Welcome to Harness**.
@MainActor
enum OnboardingController {
    private static let shownKey = "HarnessOnboardingShown_v1"
    private static var controller: OnboardingWindowController?

    /// Present on first run only. Called after the daemon is up so the app is
    /// fully interactive behind the panel.
    static func presentIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
        UserDefaults.standard.set(true, forKey: shownKey)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { present() }
    }

    /// Always present (Help menu).
    static func present() {
        if controller == nil { controller = OnboardingWindowController() }
        controller?.showWindow(nil)
        controller?.window?.center()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Window

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let pageView = NSView()
    private let dots = NSStackView()
    private let backButton = NSButton()
    private let nextButton = NSButton()
    private var pageIndex = 0
    private let pages = OnboardingPage.all

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.title = "Welcome to Harness"
        super.init(window: panel)
        panel.delegate = self
        buildLayout()
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var chrome: HarnessChromePalette { HarnessChrome.current }

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = chrome.sidebarBackground.cgColor

        pageView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pageView)

        // Footer: page dots (left) + Back / Next (right).
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(footer)

        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.orientation = .horizontal
        dots.spacing = 7
        footer.addSubview(dots)

        backButton.title = "Back"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(back)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.title = "Next"
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(next)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [backButton, nextButton])
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(buttons)

        NSLayoutConstraint.activate([
            pageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            pageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            pageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            pageView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            footer.heightAnchor.constraint(equalToConstant: 32),

            dots.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            dots.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            buttons.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])

        rebuildDots()
    }

    private func rebuildDots() {
        dots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for index in pages.indices {
            let dot = NSView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3.5
            dot.layer?.backgroundColor = (index == pageIndex ? chrome.accent : chrome.border).cgColor
            dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
            dots.addArrangedSubview(dot)
        }
    }

    @objc private func back() {
        guard pageIndex > 0 else { return }
        pageIndex -= 1
        render()
    }

    @objc private func next() {
        if pageIndex >= pages.count - 1 { close(); return }
        pageIndex += 1
        render()
    }

    private func render() {
        pageView.subviews.forEach { $0.removeFromSuperview() }
        let page = pages[pageIndex]
        let body = page.isShortcuts ? buildShortcutsView() : buildContentView(page)
        body.translatesAutoresizingMaskIntoConstraints = false
        pageView.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: pageView.topAnchor),
            body.leadingAnchor.constraint(equalTo: pageView.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: pageView.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: pageView.bottomAnchor),
        ])
        backButton.isHidden = pageIndex == 0
        nextButton.title = pageIndex == pages.count - 1 ? "Get Started" : "Next"
        rebuildDots()
    }

    // MARK: Page renderers

    private func buildContentView(_ page: OnboardingPage) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let badge = NSTextField(labelWithString: page.glyph)
        badge.font = .systemFont(ofSize: 44)
        stack.addArrangedSubview(badge)

        let title = NSTextField(labelWithString: page.title)
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.textColor = chrome.textPrimary
        stack.addArrangedSubview(title)

        if let subtitle = page.subtitle {
            let sub = NSTextField(wrappingLabelWithString: subtitle)
            sub.font = .systemFont(ofSize: 14)
            sub.textColor = chrome.textSecondary
            sub.preferredMaxLayoutWidth = 660
            stack.addArrangedSubview(sub)
            stack.setCustomSpacing(20, after: sub)
        }

        for bullet in page.bullets {
            stack.addArrangedSubview(bulletRow(bullet))
        }

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
        ])
        return container
    }

    /// A bullet: an optional key chip + descriptive text.
    private func bulletRow(_ bullet: OnboardingPage.Bullet) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        if let key = bullet.key {
            row.addArrangedSubview(keyChip(key))
        }
        let text = NSTextField(wrappingLabelWithString: bullet.text)
        text.font = .systemFont(ofSize: 13.5)
        text.textColor = chrome.textPrimary
        text.preferredMaxLayoutWidth = bullet.key == nil ? 660 : 540
        row.addArrangedSubview(text)
        return row
    }

    private func keyChip(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = chrome.textPrimary
        label.alignment = .center
        let chip = PaddedChip(label: label, palette: chrome)
        chip.setContentHuggingPriority(.required, for: .horizontal)
        return chip
    }

    private func buildShortcutsView() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "⌨  Keyboard shortcuts")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = chrome.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let hint = NSTextField(wrappingLabelWithString: "Reopen this guide anytime from Help → Welcome to Harness, or press the prefix then ? for the live cheatsheet.")
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = chrome.textSecondary
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)

        // Scrollable two-column grid of shortcuts.
        let grid = NSGridView()
        grid.columnSpacing = 16
        grid.rowSpacing = 7
        grid.translatesAutoresizingMaskIntoConstraints = false
        for entry in OnboardingShortcuts.entries() {
            if entry.isHeader {
                let header = NSTextField(labelWithString: entry.action.uppercased())
                header.font = .systemFont(ofSize: 10.5, weight: .semibold)
                header.textColor = chrome.textTertiary
                let row = grid.addRow(with: [header, NSGridCell.emptyContentView])
                row.topPadding = 8
            } else {
                let key = NSTextField(labelWithString: entry.key)
                key.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
                key.textColor = chrome.accent
                let action = NSTextField(labelWithString: entry.action)
                action.font = .systemFont(ofSize: 13)
                action.textColor = chrome.textPrimary
                grid.addRow(with: [key, action])
            }
        }
        grid.column(at: 0).xPlacement = .trailing

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        scroll.documentView = doc
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 4),
            doc.trailingAnchor.constraint(greaterThanOrEqualTo: grid.trailingAnchor, constant: 4),
            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return container
    }
}

// MARK: - Key chip view

@MainActor
private final class PaddedChip: NSView {
    init(label: NSTextField, palette: HarnessChromePalette) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = palette.surfaceElevated.cgColor
        layer?.borderColor = palette.border.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Page model

@MainActor
private struct OnboardingPage {
    var glyph: String
    var title: String
    var subtitle: String?
    var bullets: [Bullet]
    var isShortcuts: Bool = false

    struct Bullet { var key: String?; var text: String }

    static var prefix: String {
        let raw = SessionCoordinator.shared.settings.prefixKey
        guard let spec = KeySpec.parse(raw) else { return "Ctrl-A" }
        return spec.description.replacingOccurrences(of: "C-", with: "Ctrl-")
    }

    static var all: [OnboardingPage] {
        let p = prefix
        return [
            OnboardingPage(
                glyph: "🪢",
                title: "Welcome to Harness",
                subtitle: "A native macOS terminal with a built-in multiplexer — splits, tabs, sessions, and detachable windows, all GPU-rendered. Think tmux's power with a real Mac UI.",
                bullets: [
                    .init(key: nil, text: "Your sessions live in a background daemon, so they survive closing the window — reopen and everything's still running."),
                    .init(key: nil, text: "Drive everything by mouse, by menu, or by keyboard. This guide shows the fast way."),
                ]
            ),
            OnboardingPage(
                glyph: "⌘",
                title: "The prefix key",
                subtitle: "Multiplexer commands start with a prefix press, then a key — just like tmux. Your prefix is \(p). Press it, release, then the command key.",
                bullets: [
                    .init(key: "\(p) c", text: "New tab"),
                    .init(key: "\(p) %", text: "Split the pane side-by-side"),
                    .init(key: "\(p) \"", text: "Split the pane top/bottom"),
                    .init(key: "\(p) ?", text: "Live cheatsheet of every prefix binding"),
                    .init(key: nil, text: "Change the prefix anytime in Settings → Keys."),
                ]
            ),
            OnboardingPage(
                glyph: "⊟",
                title: "Panes & splits",
                subtitle: "Split any pane into a grid. Each pane is a full shell. Navigate, zoom, and rearrange without the mouse.",
                bullets: [
                    .init(key: "⌘D", text: "Split side-by-side  ·  ⌘⇧D top/bottom"),
                    .init(key: "\(p) →←↑↓", text: "Move focus between panes"),
                    .init(key: "\(p) z", text: "Zoom the active pane to fullscreen (toggle)"),
                    .init(key: "\(p) x", text: "Close the active pane"),
                    .init(key: "\(p) Space", text: "Cycle layouts (even, main, tiled)"),
                ]
            ),
            OnboardingPage(
                glyph: "▤",
                title: "Tabs, sessions & workspaces",
                subtitle: "Harness nests your work: a workspace holds sessions (sidebar rows), a session holds tabs, a tab holds the pane layout.",
                bullets: [
                    .init(key: "⌘T", text: "New tab  ·  ⌘⇧[ / ⌘⇧] to switch tabs"),
                    .init(key: "⌘1–9", text: "Jump to a workspace"),
                    .init(key: "\(p) ,", text: "Rename the current tab"),
                    .init(key: "⌘K", text: "Command palette — search themes & actions"),
                ]
            ),
            OnboardingPage(
                glyph: "⇄",
                title: "Attach from anywhere",
                subtitle: "Because the daemon owns your sessions, you can render a window's full split layout in any plain terminal — even over ssh — with the CLI.",
                bullets: [
                    .init(key: "harness-cli attach-window", text: "Render the current window's panes, borders, and status line in any terminal"),
                    .init(key: "harness-cli -CC", text: "Control mode — drive Harness from scripts/tools"),
                    .init(key: nil, text: "Multiple clients can attach to the same session; the view sizes to the smallest so nothing is truncated."),
                ]
            ),
            OnboardingPage(
                glyph: "🤖",
                title: "Agent-aware",
                subtitle: "Harness detects coding agents (Claude Code, Codex, Cursor, and more) running in your panes and surfaces when they need you.",
                bullets: [
                    .init(key: nil, text: "An agent chip appears on the tab; the bell badges when an agent is waiting for input."),
                    .init(key: "⌘⇧U", text: "Jump to the next pane awaiting your attention"),
                    .init(key: "harness-cli install-hooks", text: "Wire up notifications for your agent of choice"),
                ]
            ),
            OnboardingPage(glyph: "", title: "", subtitle: nil, bullets: [], isShortcuts: true),
        ]
    }
}

// MARK: - Shortcut guide data

@MainActor
enum OnboardingShortcuts {
    struct Entry { var key: String; var action: String; var isHeader: Bool = false }

    /// Global menu shortcuts (static) + the live prefix bindings from
    /// `keybindings.json`, so the guide always matches the user's real config.
    static func entries() -> [Entry] {
        var entries: [Entry] = [
            .init(key: "", action: "Global", isHeader: true),
            .init(key: "⌘T", action: "New tab"),
            .init(key: "⌘⇧N", action: "New workspace"),
            .init(key: "⌘W", action: "Close tab"),
            .init(key: "⌘D / ⌘⇧D", action: "Split side-by-side / top-bottom"),
            .init(key: "⌘⇧[ / ⌘⇧]", action: "Previous / next tab"),
            .init(key: "⌘1–9", action: "Switch workspace"),
            .init(key: "⌘K", action: "Command palette"),
            .init(key: "⌘;", action: "Command prompt"),
            .init(key: "⌘,", action: "Settings"),
            .init(key: "⌘\\", action: "Toggle sidebar"),
            .init(key: "⌘⇧U", action: "Jump to waiting agent"),
            .init(key: "⌘+ / ⌘-", action: "Font size"),
        ]

        let prefix = OnboardingPage.prefix
        let table = KeybindingsStore.load().table(.prefix)
        if let bindings = table?.bindings, !bindings.isEmpty {
            entries.append(.init(key: "", action: "Prefix (\(prefix) then…)", isHeader: true))
            for binding in bindings {
                let keyText = binding.spec.description
                    .replacingOccurrences(of: "C-", with: "Ctrl-")
                    .replacingOccurrences(of: "S-", with: "⇧")
                entries.append(.init(key: "\(prefix) \(keyText)", action: binding.note ?? binding.command.shortDescription))
            }
        }
        return entries
    }
}
