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

    private enum SelectionMode { case none, char, line, block }
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
        // Data-driven: resolve the keystroke against the (rebindable) copy-mode
        // table and run the resulting `copy-mode -X` action. Users customize copy
        // mode with `bind-key -T copy-mode <key> <command>`.
        guard let spec = Self.keySpec(from: event),
              let binding = KeybindingsService.shared.lookup(table: .copyMode, spec: spec),
              case let .copyModeCommand(action) = binding.command
        else { return false }
        perform(action)
        return true
    }

    /// Run a copy-mode action (dispatched from the key table or `copy-mode -X`).
    func perform(_ action: CopyModeAction) {
        switch action {
        case .cursorLeft: move(by: -1, extend: selection != .none)
        case .cursorRight: move(by: 1, extend: selection != .none)
        case .cursorDown: moveLine(by: 1)
        case .cursorUp: moveLine(by: -1)
        case .nextWord: moveByWord(forward: true)
        case .previousWord: moveByWord(forward: false)
        case .startOfLine: moveToLineStart()
        case .endOfLine: moveToLineEnd()
        case .top: moveToTop()
        case .bottom: moveToBottom()
        case .pageUp: moveLine(by: -visibleLineCount())
        case .pageDown: moveLine(by: visibleLineCount())
        case .halfPageUp: moveLine(by: -max(1, visibleLineCount() / 2))
        case .halfPageDown: moveLine(by: max(1, visibleLineCount() / 2))
        case .beginSelection:
            selection = (selection == .char) ? .none : .char
            anchor = textView.selectedRange().location
            updateStatus()
        case .selectLine:
            selection = (selection == .line) ? .none : .line
            if selection == .line { extendToFullLine() } else { applyCursor(textView.selectedRange().location) }
            updateStatus()
        case .rectangleToggle:
            if selection == .block {
                selection = .char
            } else {
                if selection == .none { anchor = textView.selectedRange().location }
                selection = .block
            }
            applyCursor(textView.selectedRange().location)
            updateStatus()
        case .clearSelection:
            selection = .none
            applyCursor(textView.selectedRange().location)
            updateStatus()
        case .searchForward: beginSearch(reverse: false)
        case .searchBackward: beginSearch(reverse: true)
        case .searchAgain: if let q = lastSearch { findNext(q, reverse: lastSearchReverse) }
        case .searchReverse: if let q = lastSearch { findNext(q, reverse: !lastSearchReverse) }
        case .copySelection: yankSelection(cancel: false)
        case .copySelectionAndCancel: yankSelection(cancel: true)
        case let .copyPipe(command): copyPipe(command)
        case .paste: pasteMostRecentBufferIntoSurface()
        case .cancel: close()
        }
    }

    /// Number of fully visible text lines, for page motions.
    private func visibleLineCount() -> Int {
        let lineHeight = max(1, textView.font?.boundingRectForFont.height ?? 16)
        let height = scroll.contentView.bounds.height
        return max(1, Int(height / lineHeight))
    }

    /// Convert an `NSEvent` to a `KeySpec` for copy-mode table lookup (mirrors the
    /// prefix keymap's mapping; kept local so the working prefix path is untouched).
    static func keySpec(from event: NSEvent) -> KeySpec? {
        guard let chars = event.charactersIgnoringModifiers else { return nil }
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
            default: key = chars
            }
        } else {
            key = chars
        }
        var modifiers: KeySpec.Modifiers = []
        let mask = event.modifierFlags
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.command) { modifiers.insert(.command) }
        if mask.contains(.shift), key.count > 1 { modifiers.insert(.shift) }
        return KeySpec(key: key, modifiers: modifiers)
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
        switch selection {
        case .line:
            extendLineSelection(at: clamped)
            return
        case .block:
            applyBlockHighlight(to: clamped)
            textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
            updateStatus()
            return
        case .none:
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
        case .char:
            let lo = min(anchor, clamped)
            let hi = max(anchor, clamped)
            textView.setSelectedRange(NSRange(location: lo, length: hi - lo))
        }
        textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
        updateStatus()
    }

    // MARK: - Rectangle (block) selection

    /// Character offset where each line starts (line 0 at 0, then after each \n).
    private func lineStartOffsets() -> [Int] {
        let ns = sourceText as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 0x0A { starts.append(i + 1) }
            i += 1
        }
        return starts
    }

    private func rowCol(_ loc: Int) -> (row: Int, col: Int) {
        let starts = lineStartOffsets()
        let clamped = max(0, min((sourceText as NSString).length, loc))
        var row = 0
        for (i, start) in starts.enumerated() where start <= clamped { row = i }
        return (row, clamped - starts[row])
    }

    /// Highlight the rectangle between `anchor` and the cursor as one range per row.
    private func applyBlockHighlight(to location: Int) {
        let ns = sourceText as NSString
        let starts = lineStartOffsets()
        let a = rowCol(anchor), c = rowCol(location)
        let r0 = min(a.row, c.row), r1 = max(a.row, c.row)
        let c0 = min(a.col, c.col), c1 = max(a.col, c.col)
        var ranges: [NSValue] = []
        for r in r0...r1 where r < starts.count {
            let start = starts[r]
            let lineEnd = (r + 1 < starts.count) ? starts[r + 1] - 1 : ns.length
            let lineLen = max(0, lineEnd - start)
            let lo = min(c0, lineLen), hi = min(c1, lineLen)
            ranges.append(NSValue(range: NSRange(location: start + lo, length: max(0, hi - lo))))
        }
        if ranges.isEmpty { ranges = [NSValue(range: NSRange(location: location, length: 0))] }
        textView.selectedRanges = ranges
    }

    /// Text of the current block selection: per row, the column slice, joined by \n.
    private func blockSelectedText() -> String {
        let ns = sourceText as NSString
        let starts = lineStartOffsets()
        let a = rowCol(anchor), c = rowCol(textView.selectedRange().location)
        let r0 = min(a.row, c.row), r1 = max(a.row, c.row)
        let c0 = min(a.col, c.col), c1 = max(a.col, c.col)
        var out: [String] = []
        for r in r0...r1 where r < starts.count {
            let start = starts[r]
            let lineEnd = (r + 1 < starts.count) ? starts[r + 1] - 1 : ns.length
            let lineLen = max(0, lineEnd - start)
            let lo = min(c0, lineLen), hi = min(c1, lineLen)
            out.append(hi > lo ? ns.substring(with: NSRange(location: start + lo, length: hi - lo)) : "")
        }
        return out.joined(separator: "\n")
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

    /// Currently selected text, honoring rectangle (block) mode.
    private func currentSelectionText() -> String {
        if selection == .block { return blockSelectedText() }
        let range = textView.selectedRange()
        guard range.length > 0 else { return "" }
        return (sourceText as NSString).substring(with: range)
    }

    private func yankSelection(cancel: Bool) {
        let snippet = currentSelectionText()
        guard !snippet.isEmpty else {
            updateStatus(extra: "no selection")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        // Also push to the daemon's buffer store so other clients see it.
        if let data = snippet.data(using: .utf8) {
            _ = try? DaemonClient().request(.setBuffer(name: nil, data: data), timeout: 1)
        }
        if cancel { close() } else { updateStatus(extra: "copied") }
    }

    /// `copy-pipe`: pipe the selected text to a shell command's stdin (the command
    /// runs detached; e.g. `pbcopy`, `tmux load-buffer -`). Then cancel, like tmux.
    private func copyPipe(_ command: String) {
        let snippet = currentSelectionText()
        guard !snippet.isEmpty, !command.isEmpty else { close(); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardInput = pipe
        if (try? process.run()) != nil {
            pipe.fileHandleForWriting.write(Data(snippet.utf8))
            try? pipe.fileHandleForWriting.close()
        }
        close()
    }

    private func pasteMostRecentBufferIntoSurface() {
        guard let surfaceID else { return }
        _ = try? DaemonClient().request(.pasteBuffer(surfaceID: surfaceID.uuidString, name: nil, bracketed: false), timeout: 1)
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
        case .block: modeName = "V-BLOCK"
        }
        let summary = extra.isEmpty ? "" : " · \(extra)"
        statusLabel.stringValue = "-- \(modeName) --  \(row):\(col)\(summary)  ·  hjkl move  v/V/C-v select  /  search  y yank  p paste  q quit"
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
