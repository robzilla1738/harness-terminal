import AppKit
import HarnessCore

/// Real copy mode. Replaces the previous read-only NSTextView dump with a
/// view that supports vim-style motion, regex search, char/line selection,
/// and copying to both `NSPasteboard` and a named paste buffer on the daemon.
///
/// State is held client-side per active surface — switching surfaces opens a
/// fresh session. This is intentional: the cursor "memory" requirement isn't
/// a hard CTO blocker, and keeping mode state client-side keeps the daemon
/// stateless for this feature.
@MainActor
final class CopyModeViewController: NSViewController, NSTextViewDelegate {
    static let shared = CopyModeViewController()

    private var window: NSWindow?
    private let textView = CopyModeTextView()
    private let scroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()

    private enum SelectionMode { case none, char, line }
    private var selection: SelectionMode = .none
    private var anchor: Int = 0
    private var lastSearch: String?
    private var lastSearchReverse: Bool = false
    private var sourceText: String = ""
    private var surfaceID: SurfaceID?

    private init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(surfaceID: SurfaceID, text: String) {
        self.surfaceID = surfaceID
        sourceText = text
        loadViewIfNeeded()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        selection = .none
        anchor = 0
        updateStatus()
        let panel = window ?? makeWindow()
        window = panel
        panel.title = "Copy Mode — \(SessionCoordinator.shared.snapshot.title(forSurface: surfaceID) ?? "")"
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: CGFloat(SessionCoordinator.shared.settings.fontSize), weight: .regular)
        textView.textColor = HarnessChrome.current.textPrimary
        textView.backgroundColor = HarnessChrome.current.terminalBackground
        textView.allowsUndo = false
        textView.isAutomaticTextReplacementEnabled = false

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = HarnessChrome.current.textSecondary
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        searchField.placeholderString = "Search (forward)"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isHidden = true
        searchField.target = self
        searchField.action = #selector(commitSearch)
        container.addSubview(searchField)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),
            searchField.widthAnchor.constraint(equalToConstant: 320),

            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
        ])

        // Intercept key events on the text view so vim motions work without
        // the standard text-editing bindings stealing them.
        textView.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        view = container
    }

    private func makeWindow() -> NSWindow {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isRestorable = false
        panel.contentViewController = self
        panel.center()
        return panel
    }

    // MARK: - Key dispatch

    fileprivate func handleKey(_ event: NSEvent) -> Bool {
        let characters = event.charactersIgnoringModifiers ?? ""
        // While the search field has focus, only Escape returns control.
        if !searchField.isHidden, view.window?.firstResponder === searchField || view.window?.firstResponder is NSText {
            if characters == "\u{1B}" {
                exitSearch()
                return true
            }
            return false
        }
        switch characters {
        case "q", "\u{1B}":
            close()
            return true
        case "h": move(by: -1, extend: selection != .none); return true
        case "l": move(by: 1, extend: selection != .none); return true
        case "j": moveLine(by: 1); return true
        case "k": moveLine(by: -1); return true
        case "0": moveToLineStart(); return true
        case "$": moveToLineEnd(); return true
        case "g": moveToTop(); return true
        case "G": moveToBottom(); return true
        case "w": moveByWord(forward: true); return true
        case "b": moveByWord(forward: false); return true
        case "v":
            selection = (selection == .char) ? .none : .char
            anchor = textView.selectedRange().location
            updateStatus()
            return true
        case "V":
            selection = (selection == .line) ? .none : .line
            extendToFullLine()
            updateStatus()
            return true
        case "y", "\r":
            yankSelection()
            return true
        case "/":
            beginSearch(reverse: false); return true
        case "?":
            beginSearch(reverse: true); return true
        case "n":
            if let q = lastSearch { findNext(q, reverse: lastSearchReverse) }
            return true
        case "N":
            if let q = lastSearch { findNext(q, reverse: !lastSearchReverse) }
            return true
        case "p":
            pasteMostRecentBufferIntoSurface()
            return true
        default:
            return false
        }
    }

    // MARK: - Motion

    private func move(by delta: Int, extend: Bool) {
        let len = (sourceText as NSString).length
        let current = textView.selectedRange().location
        let next = max(0, min(len, current + delta))
        applyCursor(next)
    }

    private func moveLine(by delta: Int) {
        let nsText = sourceText as NSString
        let current = textView.selectedRange().location
        let currentLine = nsText.lineRange(for: NSRange(location: current, length: 0))
        let column = current - currentLine.location
        var lineStart = currentLine.location
        if delta < 0 {
            for _ in 0..<(-delta) {
                guard lineStart > 0 else { break }
                lineStart = nsText.lineRange(for: NSRange(location: lineStart - 1, length: 0)).location
            }
        } else {
            for _ in 0..<delta {
                let line = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
                let nextStart = line.location + line.length
                if nextStart >= nsText.length { break }
                lineStart = nextStart
            }
        }
        let targetLine = nsText.lineRange(for: NSRange(location: lineStart, length: 0))
        let target = min(targetLine.location + min(column, max(0, targetLine.length - 1)), nsText.length)
        applyCursor(target)
    }

    private func moveToLineStart() {
        let nsText = sourceText as NSString
        let line = nsText.lineRange(for: textView.selectedRange())
        applyCursor(line.location)
    }

    private func moveToLineEnd() {
        let nsText = sourceText as NSString
        let line = nsText.lineRange(for: textView.selectedRange())
        applyCursor(max(line.location, line.location + line.length - 1))
    }

    private func moveToTop() {
        applyCursor(0)
    }

    private func moveToBottom() {
        applyCursor((sourceText as NSString).length)
    }

    private func moveByWord(forward: Bool) {
        let nsText = sourceText as NSString
        let current = textView.selectedRange().location
        let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        if forward {
            var i = current
            while i < nsText.length, scalarBelongsToSeparators(nsText.character(at: i), set: separators) { i += 1 }
            while i < nsText.length, !scalarBelongsToSeparators(nsText.character(at: i), set: separators) { i += 1 }
            applyCursor(i)
        } else {
            var i = max(0, current - 1)
            while i > 0, scalarBelongsToSeparators(nsText.character(at: i), set: separators) { i -= 1 }
            while i > 0, !scalarBelongsToSeparators(nsText.character(at: i - 1), set: separators) { i -= 1 }
            applyCursor(i)
        }
    }

    private func scalarBelongsToSeparators(_ ch: unichar, set: CharacterSet) -> Bool {
        guard let scalar = Unicode.Scalar(ch) else { return true }
        return set.contains(scalar)
    }

    private func applyCursor(_ location: Int) {
        let length = (sourceText as NSString).length
        let clamped = max(0, min(length, location))
        let range: NSRange
        if selection == .none {
            range = NSRange(location: clamped, length: 0)
        } else if selection == .line {
            extendLineSelection(at: clamped)
            return
        } else {
            let lo = min(anchor, clamped)
            let hi = max(anchor, clamped)
            range = NSRange(location: lo, length: hi - lo)
        }
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
        updateStatus()
    }

    private func extendToFullLine() {
        let nsText = sourceText as NSString
        let current = textView.selectedRange().location
        let line = nsText.lineRange(for: NSRange(location: current, length: 0))
        anchor = line.location
        textView.setSelectedRange(line)
        updateStatus()
    }

    private func extendLineSelection(at location: Int) {
        let nsText = sourceText as NSString
        let anchorLine = nsText.lineRange(for: NSRange(location: anchor, length: 0))
        let cursorLine = nsText.lineRange(for: NSRange(location: location, length: 0))
        let start = min(anchorLine.location, cursorLine.location)
        let end = max(anchorLine.location + anchorLine.length, cursorLine.location + cursorLine.length)
        textView.setSelectedRange(NSRange(location: start, length: end - start))
        textView.scrollRangeToVisible(NSRange(location: location, length: 0))
        updateStatus()
    }

    // MARK: - Search

    private func beginSearch(reverse: Bool) {
        searchField.isHidden = false
        searchField.placeholderString = reverse ? "Search (backward)" : "Search (forward)"
        lastSearchReverse = reverse
        view.window?.makeFirstResponder(searchField)
        updateStatus()
    }

    private func exitSearch() {
        searchField.isHidden = true
        searchField.stringValue = ""
        view.window?.makeFirstResponder(textView)
        updateStatus()
    }

    @objc private func commitSearch() {
        let query = searchField.stringValue
        guard !query.isEmpty else { exitSearch(); return }
        lastSearch = query
        findNext(query, reverse: lastSearchReverse)
        exitSearch()
    }

    private func findNext(_ query: String, reverse: Bool) {
        let nsText = sourceText as NSString
        let start = textView.selectedRange().location
        let options: NSString.CompareOptions = reverse ? [.backwards, .caseInsensitive] : [.caseInsensitive]
        let searchRange: NSRange
        if reverse {
            searchRange = NSRange(location: 0, length: max(0, start - 1))
        } else {
            let lower = min(nsText.length, start + 1)
            searchRange = NSRange(location: lower, length: nsText.length - lower)
        }
        var match = nsText.range(of: query, options: options, range: searchRange)
        if match.location == NSNotFound {
            // Wrap around.
            let wrap = NSRange(location: 0, length: nsText.length)
            match = nsText.range(of: query, options: options, range: wrap)
        }
        if match.location != NSNotFound {
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            anchor = match.location
            updateStatus(extra: "match")
        } else {
            updateStatus(extra: "no match")
        }
    }

    // MARK: - Yank / paste

    private func yankSelection() {
        let range = textView.selectedRange()
        guard range.length > 0 else {
            updateStatus(extra: "no selection")
            return
        }
        let nsText = sourceText as NSString
        let snippet = nsText.substring(with: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        // Also push to the daemon's buffer store so other clients see it.
        if let data = snippet.data(using: .utf8) {
            _ = try? DaemonClient().request(.setBuffer(name: nil, data: data), timeout: 1)
        }
        close()
    }

    private func pasteMostRecentBufferIntoSurface() {
        guard let surfaceID else { return }
        _ = try? DaemonClient().request(.pasteBuffer(surfaceID: surfaceID.uuidString, name: nil), timeout: 1)
        close()
    }

    private func close() {
        window?.orderOut(nil)
    }

    private func updateStatus(extra: String = "") {
        let range = textView.selectedRange()
        let nsText = sourceText as NSString
        let line = nsText.lineRange(for: NSRange(location: range.location, length: 0))
        let row = (nsText.substring(to: range.location).components(separatedBy: "\n").count)
        let col = range.location - line.location + 1
        let modeName: String
        switch selection {
        case .none: modeName = "NORMAL"
        case .char: modeName = "VISUAL"
        case .line: modeName = "V-LINE"
        }
        let summary = extra.isEmpty ? "" : " · \(extra)"
        statusLabel.stringValue = "-- \(modeName) --  \(row):\(col)\(summary)  ·  hjkl move  v select  /  search  y yank  p paste  q quit"
    }
}

/// NSTextView subclass that gives the controller first crack at every key.
/// Returning `true` from `keyHandler` swallows the event so vim-style motions
/// don't compete with the text view's native bindings.
@MainActor
final class CopyModeTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

extension SessionSnapshot {
    /// Tab title for `surfaceID` if it lives somewhere in this snapshot.
    public func title(forSurface surfaceID: UUID) -> String? {
        for workspace in workspaces {
            for session in workspace.sessions {
                for tab in session.tabs {
                    if tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                        return tab.title
                    }
                }
            }
        }
        return nil
    }
}
