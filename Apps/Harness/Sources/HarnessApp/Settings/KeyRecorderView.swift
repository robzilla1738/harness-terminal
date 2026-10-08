import AppKit
import HarnessCore

/// A focusable pill that captures the next keystroke and emits a normalized
/// prefix-key string (e.g. `ctrl-a`, `cmd-shift-p`) in the same format
/// `ParsedShortcut.parse` understands. Click (or Space / Return while it has keyboard
/// focus) → "Press a key…" → the recorded shortcut is shown as glyphs (⌃A) and the raw
/// string is reported via `onChange` so the caller can save it to settings. Tabbing onto
/// the recorder only focuses it, so Tab can still move on to the next control.
@MainActor
final class KeyRecorderView: NSView {
    /// The serialized shortcut, lower-cased dash form (`ctrl-a`). Empty string
    /// means "no prefix" (prefix mode disabled).
    private(set) var value: String

    var onChange: ((String) -> Void)?
    /// What the pill says when no shortcut is set.
    private let emptyTitle: String

    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Click to record")
    private let clearButton = NSButton()
    private var recording = false {
        didSet { updateAppearance() }
    }
    private var monitor: Any?
    private var isFocused = false { didSet { updateAppearance() } }

    init(initial: String, emptyTitle: String = "None") {
        self.value = initial
        self.emptyTitle = emptyTitle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false

        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.isEditable = false
        hint.isSelectable = false
        hint.drawsBackground = false
        hint.isBezeled = false
        hint.isHidden = true

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .accessoryBarAction
        clearButton.isBordered = false
        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Clear shortcut")
        clearButton.imagePosition = .imageOnly
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.contentTintColor = .secondaryLabelColor

        addSubview(label)
        addSubview(hint)
        addSubview(clearButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        refresh()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; stopRecording(); return true }
    override func accessibilityPerformPress() -> Bool { startRecording(); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if !clearButton.isHidden,
           clearButton.bounds.contains(clearButton.convert(point, from: self)) {
            return clearButton
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        startRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            // Space or Return arms the recorder from the keyboard, like pressing a button.
            if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        _ = record(event)
    }

    /// A bare Tab / Shift-Tab is never a sensible prefix or hotkey; while recording it gives
    /// up and moves focus on, so keyboard users can't get trapped in the recorder.
    private static func isFocusTraversal(_ event: NSEvent) -> Bool {
        event.keyCode == 48 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        refresh()
        PrefixKeymap.shared.setShortcutRecordingActive(true)
        PaletteShortcuts.shared.setPaused(true, by: self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { self.stopRecording(); return nil }
            if Self.isFocusTraversal(event) { self.stopRecording(); return event }
            return self.record(event) ? nil : event
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        PrefixKeymap.shared.setShortcutRecordingActive(false)
        PaletteShortcuts.shared.setPaused(false, by: self)
        refresh()
    }

    @objc private func clear() {
        value = ""
        onChange?("")
        refresh()
    }

    /// Re-derive colors after a theme change (Settings re-skins every themed control).
    func applyChrome() {
        refresh()
        updateAppearance()
    }

    private func refresh() {
        let c = HarnessChrome.current
        clearButton.isHidden = value.isEmpty
        clearButton.contentTintColor = c.textTertiary
        hint.textColor = c.textSecondary
        if recording {
            label.stringValue = ""
            hint.isHidden = false
            hint.stringValue = "Press a key… (Esc to cancel)"
        } else {
            hint.isHidden = true
            label.stringValue = value.isEmpty ? emptyTitle : ShortcutRecorderSerializer.glyphString(for: value)
            label.textColor = value.isEmpty ? c.textSecondary : c.textPrimary
        }
    }

    /// Monochrome states — never the system accent. Recording lifts the fill toward the
    /// foreground and brightens the border; resting matches the themed field surface.
    private func updateAppearance() {
        let c = HarnessChrome.current
        layer?.backgroundColor = (recording ? c.textPrimary.withAlphaComponent(0.12) : c.surfaceElevated).cgColor
        layer?.borderColor = (recording || isFocused ? c.focusRing : c.border).cgColor
    }

    private func record(_ event: NSEvent) -> Bool {
        if Self.isFocusTraversal(event) {
            stopRecording()
            return false
        }
        guard let serialized = ShortcutRecorderSerializer.serialize(
            keyCode: event.keyCode,
            raw: event.charactersIgnoringModifiers,
            modifiers: Self.keyModifiers(from: event.modifierFlags)
        ) else { return false }
        value = serialized
        onChange?(serialized)
        stopRecording()
        return true
    }

    static func keyModifiers(from flags: NSEvent.ModifierFlags) -> KeySpec.Modifiers {
        var modifiers: KeySpec.Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

}
