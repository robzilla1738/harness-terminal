import AppKit
import HarnessTerminalEngine

/// A compact browser-style find bar that floats in the top-trailing corner of a terminal pane.
/// It owns only the UI + key handling; the actual search runs on the surface, which reports
/// match counts back through `setResults(current:total:)`.
@MainActor
final class TerminalFindBar: NSView, NSSearchFieldDelegate {
    var onQueryChanged: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    private let backdrop = NSVisualEffectView()
    private let searchField = NSSearchField()
    private let caseButton = NSButton()
    private let regexButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    /// The current match mode, read by the surface when (re)running the search.
    var searchOptions: TerminalBufferSearchOptions {
        TerminalBufferSearchOptions(isRegex: regexButton.state == .on, caseSensitive: caseButton.state == .on)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .menu
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 8
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.separatorColor.cgColor
        backdrop.maskImage = roundedMask(radius: 8)
        addSubview(backdrop)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Find"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.focusRingType = .none
        searchField.controlSize = .small

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureToggleButton(caseButton, symbol: "textformat", tooltip: "Match case", action: #selector(caseToggled))
        configureToggleButton(regexButton, symbol: "curlybraces", tooltip: "Use regular expression", action: #selector(regexToggled))
        configureIconButton(prevButton, symbol: "chevron.up", tooltip: "Previous match (⇧⌘G)", action: #selector(previousTapped))
        configureIconButton(nextButton, symbol: "chevron.down", tooltip: "Next match (⌘G)", action: #selector(nextTapped))
        configureIconButton(closeButton, symbol: "xmark", tooltip: "Close (Esc)", action: #selector(closeTapped))

        let stack = NSStackView(views: [searchField, caseButton, regexButton, countLabel, prevButton, nextButton, closeButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        backdrop.addSubview(stack)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor),
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 180),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Focus the field so the user can type immediately (selecting any prior text).
    func focusField() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    var query: String { searchField.stringValue }

    /// Update the "n of m" readout from the surface's reported match counts.
    func setResults(current: Int, total: Int) {
        if total > 0 {
            countLabel.stringValue = "\(current) of \(total)"
            countLabel.textColor = .secondaryLabelColor
        } else if searchField.stringValue.isEmpty {
            countLabel.stringValue = ""
        } else {
            countLabel.stringValue = "No results"
            countLabel.textColor = .secondaryLabelColor
        }
        let hasMatches = total > 0
        prevButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
    }

    // MARK: - Actions

    @objc private func previousTapped() { onPrevious?() }
    @objc private func nextTapped() { onNext?() }
    @objc private func closeTapped() { onClose?() }

    // Toggling a match-mode button re-runs the current query under the new options.
    @objc private func caseToggled() { updateToggleTint(caseButton); onQueryChanged?(searchField.stringValue) }
    @objc private func regexToggled() { updateToggleTint(regexButton); onQueryChanged?(searchField.stringValue) }

    // MARK: - NSSearchFieldDelegate / field editor commands

    func controlTextDidChange(_ obj: Notification) {
        onQueryChanged?(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // ⇧⏎ jumps to the previous match, ⏎ to the next.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    /// ⌘G / ⇧⌘G cycle matches while the bar (or its field editor) holds focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "g" {
            if event.modifierFlags.contains(.shift) { onPrevious?() } else { onNext?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - Helpers

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// A borderless icon button that latches on/off and tints itself with the accent color while on,
    /// so the active match modes (case / regex) read at a glance.
    private func configureToggleButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.setButtonType(.pushOnPushOff)
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        updateToggleTint(button)
    }

    private func updateToggleTint(_ button: NSButton) {
        button.contentTintColor = button.state == .on ? .controlAccentColor : .secondaryLabelColor
    }

    private func roundedMask(radius: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
