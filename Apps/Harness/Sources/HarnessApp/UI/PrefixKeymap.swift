import AppKit
import HarnessCore

/// Prefix keymap. Listens globally for the configured prefix
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
        // Root table (`bind -n`): no-prefix global bindings, consulted on every key. Empty by
        // default so normal typing passes straight through; only an explicitly-bound key is
        // swallowed and run.
        if let spec = makeSpec(from: event),
           let binding = KeybindingsService.shared.lookup(table: .root, spec: spec) {
            executeBinding(binding)
            return nil
        }
        return event
    }

    /// Bumped on every (dis)arm so stale auto-disarm timers can't kill a newer
    /// armed window (e.g. when a repeatable binding re-arms the prefix).
    private var armGeneration = 0

    private func arm() {
        armed = true
        showIndicator()
        // Auto-disarm after 2 seconds so users aren't surprised later.
        scheduleAutoDisarm(after: 2)
    }

    /// Re-arm a short window after a repeatable binding (`bind-key -r`) so the key
    /// repeats without re-pressing the prefix — tmux's `repeat-time` behavior.
    private func armRepeat() {
        armed = true
        showIndicator()
        // tmux `repeat-time` (ms); clamp to a sane floor so a misconfigured 0 doesn't make
        // repeatable bindings impossible.
        let ms = HarnessOptions.shared.get("repeat-time", scope: .global)?.intValue ?? 500
        scheduleAutoDisarm(after: max(0.05, Double(ms) / 1000))
    }

    private func scheduleAutoDisarm(after seconds: TimeInterval) {
        armGeneration += 1
        let generation = armGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.armGeneration == generation else { return }
            self.disarm()
        }
    }

    private func disarm() {
        armed = false
        armGeneration += 1 // invalidate any pending auto-disarm
        hideIndicator()
    }

    /// Map an NSEvent into a `KeySpec` so the prefix table can resolve it.
    /// Returns `nil` for events whose characters we can't represent (dead keys).
    private func makeSpec(from event: NSEvent) -> KeySpec? {
        guard let chars = event.charactersIgnoringModifiers else { return nil }
        // For ASCII printable letters, prefer the lowercase form so bindings
        // for `c` work regardless of caps lock; honor shift only for symbols.
        let key: String
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            switch scalar.value {
            case 0x1B: key = "Escape"
            case 0x09: key = "Tab"
            case 0x0D: key = "Enter"
            case 0x7F: key = "Backspace"
            case 0xF700: key = "Up"
            case 0xF701: key = "Down"
            case 0xF702: key = "Left"
            case 0xF703: key = "Right"
            case 0xF729: key = "Home"
            case 0xF72B: key = "End"
            case 0xF72C: key = "PageUp"
            case 0xF72D: key = "PageDown"
            case 0xF704...0xF70F: key = "F\(Int(scalar.value) - 0xF703)"
            default: key = chars
            }
        } else {
            key = chars
        }
        var modifiers: KeySpec.Modifiers = []
        let mask = event.modifierFlags
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.option)  { modifiers.insert(.option) }
        if mask.contains(.command) { modifiers.insert(.command) }
        // Shift is only meaningful for non-printable keys (Tab, arrows, F-keys);
        // for letters/symbols the character already reflects shift.
        if mask.contains(.shift), key.count > 1 { modifiers.insert(.shift) }
        return KeySpec(key: key, modifiers: modifiers)
    }

    private func consume(event: NSEvent) {
        guard let spec = makeSpec(from: event) else {
            NSSound.beep()
            disarm()
            return
        }
        // `:` enters the command prompt — always available under the prefix.
        if spec.key == ":" {
            CommandPromptController.shared.present()
            disarm()
            return
        }
        // Fall back to a case-insensitive letter lookup so bound `c` matches a
        // typed `C` without forcing the user to bind both forms.
        let binding = KeybindingsService.shared.lookup(table: .prefix, spec: spec)
            ?? (spec.key.count == 1
                ? KeybindingsService.shared.lookup(
                    table: .prefix,
                    spec: KeySpec(key: spec.key.lowercased(), modifiers: spec.modifiers))
                : nil)
        guard let binding else {
            NSSound.beep()
            disarm()
            return
        }
        executeBinding(binding)
        // Repeatable bindings keep the prefix armed for a short window so the key
        // can repeat; everything else disarms immediately.
        if binding.repeatable { armRepeat() } else { disarm() }
    }

    private func executeBinding(_ binding: Binding) {
        do {
            try MainExecutor.shared.execute(binding.command)
        } catch {
            fputs("PrefixKeymap: \(error)\n", stderr)
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

    /// Grouped key/action listing. Now generated from the live KeyTable so any
    /// `bind-key` change shows up immediately; group titles are inferred from
    /// the command kind so users see logical sections without us hand-curating.
    private struct Group {
        let title: String
        let entries: [(key: String, action: String)]
    }

    private static var groups: [Group] {
        let bindings = KeybindingsService.shared.bindings(in: .prefix)
        var panes: [(String, String)] = []
        var tabs: [(String, String)] = []
        var modes: [(String, String)] = []
        for binding in bindings {
            let entry = (binding.spec.description, binding.note ?? binding.command.shortDescription)
            switch binding.command {
            case .splitWindow, .killPane, .zoomPane, .selectPane, .swapPane, .resizePane:
                panes.append(entry)
            case .newWindow, .killWindow, .renameWindow, .nextWindow, .previousWindow, .selectWindow,
                 .newSession, .killSession, .renameSession, .selectWorkspace, .nextWorkspace, .previousWorkspace:
                tabs.append(entry)
            default:
                modes.append(entry)
            }
        }
        var result: [Group] = []
        if !panes.isEmpty { result.append(Group(title: "Panes", entries: panes)) }
        if !tabs.isEmpty { result.append(Group(title: "Tabs & Sessions", entries: tabs)) }
        if !modes.isEmpty { result.append(Group(title: "Modes", entries: modes)) }
        return result
    }

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
