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
    private let backButton = HarnessPillButton(title: "Back", kind: .secondary)
    private let nextButton = HarnessPillButton(title: "Next", kind: .primary)
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
        panel.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
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
        content.layer?.backgroundColor = NSColor.clear.cgColor

        // Liquid-Glass backdrop (real glass on macOS 26, vibrancy + theme tint below),
        // so onboarding reads as the same surface as the rest of the app.
        let backdrop = Self.makeGlass(tint: chrome.sidebarBackground)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(backdrop)

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

        backButton.target = self
        backButton.action = #selector(back)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(next)
        nextButton.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [backButton, nextButton])
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(buttons)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            pageView.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            pageView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 40),
            pageView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -40),
            pageView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 40),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            footer.heightAnchor.constraint(equalToConstant: 34),

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
            // Monochrome: the current page is the foreground color, the rest a faint border.
            dot.layer?.backgroundColor = (index == pageIndex ? chrome.textPrimary : chrome.border).cgColor
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
        nextButton.setTitleText(pageIndex == pages.count - 1 ? "Get started" : "Next")
        rebuildDots()
    }

    // MARK: Page renderers

    private func buildContentView(_ page: OnboardingPage) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(page.useAppIcon ? logoTile() : symbolTile(page.symbol))
        stack.setCustomSpacing(22, after: stack.arrangedSubviews[0])

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
            stack.setCustomSpacing(22, after: sub)
        }

        // Bullets laid out as a two-column grid (key | text). The grid centers each
        // cell vertically so a key chip sits flush with its description — the old
        // first-baseline stack misaligned the chip box against the text baseline.
        if !page.bullets.isEmpty {
            let grid = NSGridView()
            grid.columnSpacing = 12
            grid.rowSpacing = 12
            for bullet in page.bullets {
                let keyCell: NSView = bullet.key.map(keyChip) ?? NSGridCell.emptyContentView
                let text = NSTextField(wrappingLabelWithString: bullet.text)
                text.font = .systemFont(ofSize: 13.5)
                text.textColor = chrome.textPrimary
                text.preferredMaxLayoutWidth = bullet.key == nil ? 600 : 500
                grid.addRow(with: [keyCell, text])
            }
            grid.column(at: 0).xPlacement = .leading
            grid.column(at: 1).xPlacement = .leading
            // Center each cell vertically within its row.
            for r in 0 ..< grid.numberOfRows {
                let row = grid.row(at: r)
                for c in 0 ..< row.numberOfCells { row.cell(at: c).yPlacement = .center }
            }
            stack.addArrangedSubview(grid)
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

        let badge = symbolTile("command")
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)

        let title = NSTextField(labelWithString: "Keyboard shortcuts")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        title.textColor = chrome.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let hint = NSTextField(wrappingLabelWithString: "You can reopen this guide from Help → Welcome to Harness. Press the prefix then ? for the live cheatsheet.")
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
                key.textColor = chrome.textPrimary
                let action = NSTextField(labelWithString: entry.action)
                action.font = .systemFont(ofSize: 13)
                action.textColor = chrome.textSecondary
                grid.addRow(with: [key, action])
            }
        }
        grid.column(at: 0).xPlacement = .trailing

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView.drawsBackground = false
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        scroll.documentView = doc
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: container.topAnchor),
            badge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            title.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 18),
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

    // MARK: Badge tiles

    /// Rounded glassy tile that frames the app logo so it doesn't read as a floating
    /// icon. The app icon (its own dark rounded-square art) sits inset on the lighter
    /// elevated surface with a rim + soft shadow.
    private func logoTile() -> NSView {
        let tile = makeTile(size: 88, cornerRadius: 20)
        if let icon = HarnessDesign.brandLogo() {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 72),
                iconView.heightAnchor.constraint(equalToConstant: 72),
            ])
        }
        return tile
    }

    /// Rounded glassy tile holding a monochrome SF Symbol — the per-page badge.
    private func symbolTile(_ symbol: String) -> NSView {
        let tile = makeTile(size: 60, cornerRadius: 15)
        let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage())
        image.contentTintColor = chrome.textPrimary
        image.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(image)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            image.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        return tile
    }

    private func makeTile(size: CGFloat, cornerRadius: CGFloat) -> NSView {
        let tile = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        let c = chrome
        // Slightly stronger than surfaceElevated so the tile reads on the panel.
        tile.layer?.backgroundColor = (c.sidebarBackground.blended(withFraction: c.isDark ? 0.08 : 0.06, of: c.textPrimary) ?? c.surfaceElevated).cgColor
        tile.layer?.cornerRadius = cornerRadius
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = c.borderStrong.cgColor
        // Shadow escapes bounds (no masksToBounds); the centered content never reaches
        // the corners, so an unmasked tile still reads as a clean rounded card.
        HarnessDesign.applyShadow(.elevation2, to: tile.layer)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: size),
            tile.heightAnchor.constraint(equalToConstant: size),
        ])
        return tile
    }

    /// A glass (macOS 26) / vibrancy backdrop with a theme tint, filling the panel.
    private static func makeGlass(tint: NSColor) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
            glass.tintColor = tint
            backdrop = glass
        } else {
            let vibrancy = NSVisualEffectView()
            vibrancy.material = .underWindowBackground
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            backdrop = vibrancy
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)
        // On pre-26 the vibrancy alone is too light, so lay a near-opaque theme tint
        // over it (matching HarnessOverlayBackground); on 26 the glass tint carries it.
        let overlay = NSView()
        overlay.wantsLayer = true
        if #available(macOS 26.0, *) {
            overlay.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            overlay.layer?.backgroundColor = tint.withAlphaComponent(0.94).cgColor
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        for sub in [backdrop, overlay] {
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: container.topAnchor),
                sub.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                sub.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        return container
    }
}

// MARK: - Key chip view

@MainActor
private final class PaddedChip: NSView {
    private let label: NSTextField

    init(label: NSTextField, palette: HarnessChromePalette) {
        self.label = label
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

    /// Report the inner label's baseline (plus our top inset) so first-baseline
    /// alignment lines this chip up with adjacent text instead of treating the plain
    /// view as a baseline-less box.
    override var firstBaselineOffsetFromTop: CGFloat {
        label.firstBaselineOffsetFromTop + 3
    }
}

// MARK: - Page model

@MainActor
private struct OnboardingPage {
    var symbol: String
    var useAppIcon: Bool = false
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
                symbol: "app",
                useAppIcon: true,
                title: "Welcome to Harness",
                subtitle: "A native macOS terminal with a multiplexer built in. Split panes, keep work in tabs and sessions, and detach a window to reattach it later. Everything is GPU-rendered.",
                bullets: [
                    .init(key: nil, text: "Your sessions run in a background daemon, so they survive closing the window. Reopen and everything's still there."),
                    .init(key: nil, text: "Use the mouse, the menus, or the keyboard. This guide covers the keyboard shortcuts."),
                ]
            ),
            OnboardingPage(
                symbol: "keyboard",
                title: "The prefix key",
                subtitle: "Multiplexer commands start with a prefix press, then a key, like tmux. Your prefix is \(p). Press it, let go, then press the command key.",
                bullets: [
                    .init(key: "\(p) c", text: "New tab"),
                    .init(key: "\(p) %", text: "Split the pane side by side"),
                    .init(key: "\(p) \"", text: "Split the pane top and bottom"),
                    .init(key: "\(p) ?", text: "Show a live cheatsheet of every prefix binding"),
                    .init(key: nil, text: "You can change the prefix in Settings → Keys."),
                ]
            ),
            OnboardingPage(
                symbol: "square.split.2x1",
                title: "Panes and splits",
                subtitle: "Split any pane into a grid. Each pane is a full shell. Move between panes, zoom one to fill the window, and rearrange them from the keyboard.",
                bullets: [
                    .init(key: "⌘D", text: "Split side by side  ·  ⌘⇧D top and bottom"),
                    .init(key: "\(p) →←↑↓", text: "Move focus between panes"),
                    .init(key: "\(p) z", text: "Zoom the active pane to fill the window (toggle)"),
                    .init(key: "\(p) x", text: "Close the active pane"),
                    .init(key: "\(p) Space", text: "Cycle layouts (even, main, tiled)"),
                ]
            ),
            OnboardingPage(
                symbol: "rectangle.stack",
                title: "Tabs, sessions, and workspaces",
                subtitle: "Harness nests your work. A workspace holds sessions (the sidebar rows), a session holds tabs, and a tab holds the pane layout.",
                bullets: [
                    .init(key: "⌘T", text: "New tab  ·  ⌘⇧[ / ⌘⇧] to switch tabs"),
                    .init(key: "⌘1–9", text: "Switch to a tab"),
                    .init(key: "\(p) ,", text: "Rename the current tab"),
                    .init(key: "⌘K", text: "Command palette, to search themes and actions"),
                ]
            ),
            OnboardingPage(
                symbol: "arrow.left.arrow.right",
                title: "Attach from anywhere",
                subtitle: "The daemon owns your sessions, so you can render a window's full split layout in any plain terminal, even over ssh, using the CLI.",
                bullets: [
                    .init(key: "harness-cli attach-window", text: "Render the current window's panes, borders, and status line in any terminal"),
                    .init(key: "harness-cli -CC", text: "Control mode, for driving Harness from scripts and tools"),
                    .init(key: nil, text: "Several clients can attach to one session at once. The view sizes to the smallest so nothing gets cut off."),
                ]
            ),
            OnboardingPage(
                symbol: "sparkles",
                title: "Agent-aware",
                subtitle: "Harness spots coding agents running in your panes (Claude Code, Codex, Cursor, and others) and tells you when one needs you.",
                bullets: [
                    .init(key: nil, text: "An agent chip shows on the tab, and the bell badges when an agent is waiting on you."),
                    .init(key: "⌘⇧U", text: "Jump to the next pane that needs attention"),
                    .init(key: "harness-cli install-hooks", text: "Set up notifications for the agent you use"),
                ]
            ),
            OnboardingPage(symbol: "command", title: "", subtitle: nil, bullets: [], isShortcuts: true),
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
            .init(key: "⌘1–9", action: "Switch to tab 1–9"),
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
