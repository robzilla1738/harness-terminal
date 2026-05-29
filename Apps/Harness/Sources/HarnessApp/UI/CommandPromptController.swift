import AppKit
import HarnessCore

/// `:` command prompt. Pressing prefix `:` (or invoking via Command Palette →
/// "Run command…") brings up a single-line field anchored under the active
/// window. The text is parsed via `CommandParser` and dispatched through
/// `MainExecutor`. History persists across launches; arrow keys cycle it.
@MainActor
final class CommandPromptController: NSObject, NSTextFieldDelegate {
    static let shared = CommandPromptController()

    private var window: NSPanel?
    private let field = NSTextField()
    private var history: [String] = []
    private var historyCursor: Int = -1

    private static var historyURL: URL {
        HarnessPaths.applicationSupport.appendingPathComponent("command-history.json")
    }

    private override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.historyURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            history = saved
        }
    }

    private func saveHistory() {
        try? HarnessPaths.ensureDirectories()
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: Self.historyURL, options: .atomic)
        }
    }

    func present() {
        let panel = window ?? build()
        window = panel
        guard let keyWindow = NSApp.keyWindow else { return }
        let frame = keyWindow.frame
        let size = NSSize(width: 520, height: 36)
        panel.setFrame(
            NSRect(
                x: frame.midX - size.width / 2,
                y: frame.minY + 64,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        field.stringValue = ""
        historyCursor = -1
        panel.alphaValue = 0
        panel.orderFront(nil)
        panel.makeKey()
        panel.makeFirstResponder(field)
        HarnessMotion.animate(HarnessDesign.Motion.fast, timing: HarnessDesign.Motion.entrance) { _ in
            panel.animator().alphaValue = 1
        }
    }

    /// `command-prompt -p … "<template>"`: open the prompt seeded with the
    /// template so the user fills in any `%%`/`%1…` placeholders before running.
    func presentTemplate(prompts: [String], template: String) {
        present()
        field.stringValue = template
        // Select the first placeholder if present, else place the caret at the end.
        if let editor = field.currentEditor() {
            let ns = template as NSString
            let placeholder = ns.range(of: "%%").location != NSNotFound
                ? ns.range(of: "%%")
                : ns.range(of: "%1")
            if placeholder.location != NSNotFound {
                editor.selectedRange = placeholder
            } else {
                editor.selectedRange = NSRange(location: ns.length, length: 0)
            }
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

    // MARK: NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.moveUp(_:)):
            recallHistory(direction: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            recallHistory(direction: 1)
            return true
        default:
            return false
        }
    }

    private func commit() {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { dismiss(); return }
        if history.last != raw { history.append(raw) }
        if history.count > 100 { history.removeFirst(history.count - 100) }
        historyCursor = -1
        saveHistory()
        let source = raw
        // Dismiss first so the executed command sees no overlay (some commands
        // like `display-message` would otherwise stack on top of us).
        dismiss()
        do {
            try MainExecutor.shared.executeSource(source)
        } catch {
            DisplayMessage.show("command failed: \(error)")
        }
    }

    private func recallHistory(direction: Int) {
        guard !history.isEmpty else { return }
        if historyCursor == -1 { historyCursor = history.count }
        historyCursor = max(0, min(history.count - 1, historyCursor + direction))
        field.stringValue = history[historyCursor]
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: field.stringValue.count, length: 0)
        }
    }

    private func build() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false

        let overlay = HarnessOverlayBackground()
        overlay.frame = NSRect(x: 0, y: 0, width: 520, height: 36)

        let prompt = NSTextField(labelWithString: ":")
        prompt.font = HarnessDesign.Typography.kbd
        prompt.textColor = HarnessChrome.current.accent

        field.placeholderString = "command (e.g. split-window -h ; copy-mode)"
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.textColor = HarnessChrome.current.textPrimary
        field.bezelStyle = .roundedBezel
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        let stack = NSStackView(views: [prompt, field])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: overlay.contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: overlay.contentView.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: overlay.contentView.centerYAnchor),
        ])

        panel.contentView = overlay
        return panel
    }
}
