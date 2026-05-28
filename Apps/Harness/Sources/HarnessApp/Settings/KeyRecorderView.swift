import AppKit

/// A focusable pill that captures the next keystroke and emits a normalized
/// prefix-key string (e.g. `ctrl-a`, `cmd-shift-p`) in the same format
/// `ParsedShortcut.parse` understands. Click → "Press a key…" → the recorded
/// shortcut is shown as glyphs (⌃A) and the raw string is reported via
/// `onChange` so the caller can save it to settings.
@MainActor
final class KeyRecorderView: NSView {
    /// The serialized shortcut, lower-cased dash form (`ctrl-a`). Empty string
    /// means "no prefix" (prefix mode disabled).
    private(set) var value: String

    var onChange: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Click to record")
    private let clearButton = NSButton()
    private var recording = false {
        didSet { updateAppearance() }
    }
    private var monitor: Any?

    init(initial: String) {
        self.value = initial
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
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
        refresh()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { startRecording(); return true }
    override func resignFirstResponder() -> Bool { stopRecording(); return true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Escape cancels without changing the value.
            if event.keyCode == 53 { self.stopRecording(); return nil }
            guard let serialized = self.serialize(event) else { return nil }
            self.value = serialized
            self.onChange?(serialized)
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        refresh()
    }

    @objc private func clear() {
        value = ""
        onChange?("")
        refresh()
    }

    private func refresh() {
        clearButton.isHidden = value.isEmpty
        if recording {
            label.stringValue = ""
            hint.isHidden = false
            hint.stringValue = "Press a key… (Esc to cancel)"
        } else {
            hint.isHidden = true
            label.stringValue = value.isEmpty ? "No prefix" : Self.glyphString(for: value)
            label.textColor = value.isEmpty ? .secondaryLabelColor : .labelColor
        }
    }

    private func updateAppearance() {
        layer?.backgroundColor = (recording ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                                            : NSColor.textBackgroundColor.withAlphaComponent(0.7)).cgColor
        layer?.borderColor = (recording ? NSColor.controlAccentColor
                                        : NSColor.separatorColor.withAlphaComponent(0.6)).cgColor
    }

    /// Serialize an NSEvent into the dash-delimited form `ParsedShortcut.parse` reads.
    /// Returns nil for plain modifier-only events so the user can still press shift
    /// to compose a real shortcut.
    private func serialize(_ event: NSEvent) -> String? {
        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return nil }
        let key: String
        if raw.count == 1, let scalar = raw.unicodeScalars.first {
            switch scalar.value {
            case 0x1B: key = "escape"
            case 0x09: key = "tab"
            case 0x0D: key = "enter"
            case 0x7F: key = "backspace"
            case 0x20: key = "space"
            case 0xF700: key = "up"
            case 0xF701: key = "down"
            case 0xF702: key = "left"
            case 0xF703: key = "right"
            default:    key = raw.lowercased()
            }
        } else {
            key = raw.lowercased()
        }
        var parts: [String] = []
        let mods = event.modifierFlags
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option)  { parts.append("opt") }
        if mods.contains(.shift), key.count > 1 { parts.append("shift") }
        if mods.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "-")
    }

    private static func glyphString(for raw: String) -> String {
        let parts = raw.lowercased().split(separator: "-").map(String.init)
        guard let last = parts.last else { return raw }
        var glyphs = ""
        for component in parts.dropLast() {
            switch component {
            case "ctrl", "control": glyphs += "⌃"
            case "opt", "alt", "option": glyphs += "⌥"
            case "shift": glyphs += "⇧"
            case "cmd", "command": glyphs += "⌘"
            default: break
            }
        }
        return glyphs + last.uppercased()
    }
}
