import AppKit
import HarnessCore

/// tmux-style prefix keymap. Listens globally for the configured prefix
/// (default `Ctrl-A`); after the prefix fires, the next keystroke is consumed
/// and routed through `bindings`. Press `?` while armed to see the cheatsheet.
@MainActor
final class PrefixKeymap {
    static let shared = PrefixKeymap()

    private var monitor: Any?
    private var armed = false
    private var prefix: ParsedShortcut = .controlA
    private var indicator: PrefixIndicatorWindow?

    private init() {}

    func install() {
        rebuildFromSettings()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    func rebuildFromSettings() {
        let raw = SessionCoordinator.shared.settings.prefixKey
        prefix = ParsedShortcut.parse(raw) ?? .controlA
    }

    /// Returns nil to swallow the event or the original event to forward it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        if armed {
            consume(event: event)
            return nil
        }
        if prefix.matches(event) {
            arm()
            return nil
        }
        return event
    }

    private func arm() {
        armed = true
        showIndicator()
        // Auto-disarm after 2 seconds so users aren't surprised later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.disarm()
        }
    }

    private func disarm() {
        armed = false
        hideIndicator()
    }

    private func consume(event: NSEvent) {
        defer { disarm() }
        guard let chars = event.charactersIgnoringModifiers else { return }
        let key = chars.lowercased()
        let coordinator = SessionCoordinator.shared
        switch key {
        case "c":
            coordinator.openTabInActiveWorkspace()
        case "%":
            coordinator.splitActivePane(direction: .vertical)
        case "\"":
            coordinator.splitActivePane(direction: .horizontal)
        case "x":
            coordinator.killActivePane()
        case "z":
            coordinator.zoomActivePane()
        case "o":
            coordinator.cycleActivePane(forward: true)
        case ";":
            coordinator.cycleActivePane(forward: false)
        case "[":
            coordinator.toggleCopyMode()
        case "d":
            coordinator.detachActiveSurface()
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let idx = Int(key) {
                coordinator.selectWorkspace(byIndex: idx)
            }
        case ",":
            coordinator.beginRenameActiveTab()
        case "?":
            PrefixCheatsheetWindow.shared.toggle()
        case "r":
            coordinator.reimportFromGhostty()
        default:
            NSSound.beep()
        }
    }

    private func showIndicator() {
        let indicator = self.indicator ?? PrefixIndicatorWindow()
        self.indicator = indicator
        indicator.present(near: NSApp.keyWindow, prefix: prefix.displayString)
    }

    private func hideIndicator() {
        indicator?.dismiss()
    }
}

struct ParsedShortcut: Equatable {
    var modifiers: NSEvent.ModifierFlags
    var key: String

    static let controlA = ParsedShortcut(modifiers: .control, key: "a")

    static func parse(_ raw: String) -> ParsedShortcut? {
        let parts = raw.lowercased().split(separator: "-").map(String.init)
        guard let last = parts.last else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for component in parts.dropLast() {
            switch component {
            case "ctrl", "control": modifiers.insert(.control)
            case "cmd", "command": modifiers.insert(.command)
            case "opt", "alt", "option": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        return ParsedShortcut(modifiers: modifiers, key: last)
    }

    func matches(_ event: NSEvent) -> Bool {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else { return false }
        // Mask out caps lock + numeric noise — only the four real modifiers count.
        let mask: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        return event.modifierFlags.intersection(mask) == modifiers && chars == key
    }

    /// Human-readable glyph form, e.g. `⌃A`, for the prefix indicator.
    var displayString: String {
        var glyphs = ""
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + key.uppercased()
    }
}

@MainActor
final class PrefixIndicatorWindow {
    private var window: NSWindow?
    private let label = NSTextField(labelWithString: "⌃A")

    func present(near keyWindow: NSWindow?, prefix: String) {
        let panel = window ?? makePanel()
        window = panel
        label.stringValue = prefix
        guard let parent = keyWindow else {
            panel.orderOut(nil)
            return
        }
        let frame = parent.frame
        let size = NSSize(width: 96, height: 32)
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + 36,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        panel.alphaValue = 0
        panel.orderFront(nil)
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.spring) { _ in
            panel.animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard let window else { return }
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.exit) { _ in
            window.animator().alphaValue = 0
        } completion: {
            window.orderOut(nil)
        }
    }

    private func makePanel() -> NSWindow {
        let c = HarnessChrome.current
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 96, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let host = HarnessOverlayBackground()
        host.frame = panel.contentLayoutRect

        let prefixIcon = NSImageView()
        prefixIcon.image = NSImage(systemSymbolName: "command.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        prefixIcon.contentTintColor = c.accent
        prefixIcon.translatesAutoresizingMaskIntoConstraints = false

        label.font = HarnessDesign.Typography.kbd
        label.textColor = c.accent
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [prefixIcon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: host.contentView.centerYAnchor),
        ])

        panel.contentView = host
        return panel
    }
}

@MainActor
final class PrefixCheatsheetWindow {
    static let shared = PrefixCheatsheetWindow()
    private var window: NSWindow?
    private init() {}

    func toggle() {
        if let window, window.isVisible {
            dismiss()
            return
        }
        if window == nil { window = build() }
        guard let window else { return }
        window.center()
        window.alphaValue = 0
        window.orderFront(nil)
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.entrance) { _ in
            window.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard let window else { return }
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.exit) { _ in
            window.animator().alphaValue = 0
        } completion: {
            window.orderOut(nil)
        }
    }

    /// Grouped key/action listing — sections mirror cmux/tmux so users coming from
    /// either tool immediately recognize the layout.
    private struct Group {
        let title: String
        let entries: [(key: String, action: String)]
    }

    private static let groups: [Group] = [
        Group(title: "Panes", entries: [
            ("%", "Split right"),
            ("\"", "Split down"),
            ("z", "Toggle zoom"),
            ("x", "Kill pane"),
            ("o", "Cycle forward"),
            (";", "Cycle back"),
        ]),
        Group(title: "Tabs & Sessions", entries: [
            ("c", "New tab"),
            (",", "Rename tab"),
            ("d", "Detach surface"),
            ("0–9", "Select workspace"),
        ]),
        Group(title: "Modes", entries: [
            ("[", "Copy mode"),
            ("r", "Re-import Ghostty"),
            ("?", "Toggle this cheatsheet"),
        ]),
    ]

    private func build() -> NSWindow {
        let c = HarnessChrome.current
        let width: CGFloat = 380
        let rowHeight: CGFloat = 26
        let groupSpacing: CGFloat = 14
        let totalRows = Self.groups.reduce(0) { $0 + $1.entries.count }
        let height = CGFloat(totalRows) * rowHeight + CGFloat(Self.groups.count) * 28 + 64

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isRestorable = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let overlay = HarnessOverlayBackground()
        overlay.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.spacing = HarnessDesign.Spacing.md
        titleRow.alignment = .firstBaseline
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let prefixGlyph = NSTextField(labelWithString: ParsedShortcut.parse(SessionCoordinator.shared.settings.prefixKey)?.displayString ?? "⌃A")
        prefixGlyph.font = .monospacedSystemFont(ofSize: 12, weight: .heavy)
        prefixGlyph.textColor = c.accent
        prefixGlyph.drawsBackground = false
        let prefixWrap = pillWrap(prefixGlyph)

        let title = NSTextField(labelWithString: "Prefix Commands")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = c.textPrimary

        let hint = NSTextField(labelWithString: "press the prefix, then…")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = c.textTertiary

        titleRow.addArrangedSubview(prefixWrap)
        titleRow.addArrangedSubview(title)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(spacer)
        titleRow.addArrangedSubview(hint)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = groupSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for group in Self.groups {
            stack.addArrangedSubview(buildGroup(group, width: width))
        }

        let content = overlay.contentView
        content.addSubview(titleRow)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            titleRow.topAnchor.constraint(equalTo: content.topAnchor, constant: HarnessDesign.Spacing.lg + 2),
            titleRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HarnessDesign.Spacing.xl),
            titleRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            stack.topAnchor.constraint(equalTo: titleRow.bottomAnchor, constant: HarnessDesign.Spacing.lg),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: HarnessDesign.Spacing.xl),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -HarnessDesign.Spacing.xl),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -HarnessDesign.Spacing.lg),
        ])

        panel.contentView = overlay
        return panel
    }

    private func buildGroup(_ group: Group, width: CGFloat) -> NSView {
        let c = HarnessChrome.current
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: group.title.uppercased())
        header.font = HarnessDesign.Typography.sectionLabel
        header.textColor = c.textTertiary
        container.addArrangedSubview(header)

        for entry in group.entries {
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false

            let kbd = NSTextField(labelWithString: entry.key)
            kbd.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            kbd.textColor = c.accent
            kbd.alignment = .center
            kbd.drawsBackground = false
            let kbdWrap = pillWrap(kbd)

            let action = NSTextField(labelWithString: entry.action)
            action.font = .systemFont(ofSize: 12.5)
            action.textColor = c.textSecondary
            action.translatesAutoresizingMaskIntoConstraints = false

            row.addSubview(kbdWrap)
            row.addSubview(action)
            NSLayoutConstraint.activate([
                row.heightAnchor.constraint(equalToConstant: 26),
                kbdWrap.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                kbdWrap.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                kbdWrap.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
                action.leadingAnchor.constraint(equalTo: kbdWrap.trailingAnchor, constant: HarnessDesign.Spacing.lg),
                action.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                action.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            ])
            container.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: width - HarnessDesign.Spacing.xl * 2).isActive = true
        }

        return container
    }

    /// Wrap a label in a subtle outlined "key cap" — the pill behind every glyph.
    private func pillWrap(_ label: NSTextField) -> NSView {
        let c = HarnessChrome.current
        label.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView()
        wrap.wantsLayer = true
        wrap.layer?.cornerRadius = HarnessDesign.Radius.badge
        wrap.layer?.cornerCurve = .continuous
        wrap.layer?.borderWidth = 1
        wrap.layer?.borderColor = c.border.cgColor
        wrap.layer?.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.07 : 0.06).cgColor
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }
}
