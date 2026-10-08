import Foundation

/// `pane.capture` formats. One grid rebuild feeds text, HTML, and VT.
public enum PaneCapture {
    public static func render(bytes: Data, cols: Int, rows: Int, format: String, trim: Bool, unwrap: Bool) -> String {
        guard let term = HarnessGridTerminal(cols: cols, rows: rows) else { return "" }
        term.maxScrollbackLines = 100_000
        term.emulatorForCapture.readsGraphicsFiles = false
        term.feed(bytes)
        return render(term: term.emulatorForCapture, format: format, trim: trim, unwrap: unwrap)
    }

    /// Render the emulator the daemon already caught up. Capture calls this so the
    /// PTY read loop does not rebuild the grid.
    public static func render(term: TerminalEmulator, format: String, trim: Bool, unwrap: Bool) -> String {
        switch format {
        case "html":
            return html(term.captureCellLines(joinWrapped: unwrap), trim: trim)
        case "vt":
            return vt(term.captureCellLines(joinWrapped: unwrap), trim: trim)
        default:
            var lines = term.captureLines(joinWrapped: unwrap)
            if trim { lines = trimLines(lines) }
            return lines.joined(separator: "\n")
        }
    }

    static func trimLines(_ lines: [String]) -> [String] {
        var trimmed = lines.map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
        while trimmed.last?.isEmpty == true { trimmed.removeLast() }
        return trimmed
    }

    static func html(_ lines: [[TerminalGridCell]], trim: Bool) -> String {
        var rows = lines
        if trim {
            rows = rows.map(trimCells)
            while rows.last?.isEmpty == true { rows.removeLast() }
        }
        var body = ""
        for (index, row) in rows.enumerated() {
            if index > 0 { body += "\n" }
            body += htmlRow(row)
        }
        return "<pre>\(body)</pre>"
    }

    static func vt(_ lines: [[TerminalGridCell]], trim: Bool) -> String {
        var rows = lines
        if trim {
            rows = rows.map(trimCells)
            while rows.last?.isEmpty == true { rows.removeLast() }
        }
        return rows.map(vtRow).joined(separator: "\n")
    }

    private static func trimCells(_ cells: [TerminalGridCell]) -> [TerminalGridCell] {
        var end = cells.count
        while end > 0, isBlank(cells[end - 1]) { end -= 1 }
        return Array(cells.prefix(end))
    }

    private static func isBlank(_ cell: TerminalGridCell) -> Bool {
        cell.codepoint == 0 || cell.codepoint == 32
    }

    private static func htmlRow(_ cells: [TerminalGridCell]) -> String {
        var out = ""
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            if cell.width == .spacerTail { index += 1; continue }
            let style = htmlStyle(cell)
            let text = escape(cell.codepoint == 0 ? " " : cell.cluster)
            if style.isEmpty {
                out += text
            } else {
                out += "<span style=\"\(style)\">\(text)</span>"
            }
            index += 1
        }
        return out
    }

    private static func htmlStyle(_ cell: TerminalGridCell) -> String {
        var parts: [String] = []
        if let color = css(cell.foreground) { parts.append("color:\(color)") }
        if let color = css(cell.background) { parts.append("background:\(color)") }
        if cell.bold { parts.append("font-weight:bold") }
        return parts.joined(separator: ";")
    }

    /// The visible screen as bytes that repaint it on any terminal: the alternate screen when
    /// it's active, every row with its attributes, the cursor, and the input modes a program
    /// set (cursor keys, keypad, bracketed paste, focus and mouse reporting, Kitty keyboard).
    /// `attach` paints this instead of replaying history.
    public static func screen(_ term: TerminalEmulator) -> Data {
        let grid = term.readGrid()
        var out = term.isAlternateScreenActive ? "\u{1b}[?1049h" : ""
        out += "\u{1b}[0m\u{1b}[H\u{1b}[2J"
        for row in 0 ..< grid.rows {
            let start = row * grid.cols
            var cells = Array(grid.cells[start ..< start + grid.cols])
            while let last = cells.last, isBlank(last), last.background == .none, !last.inverse { cells.removeLast() }
            guard !cells.isEmpty else { continue }
            out += "\u{1b}[\(row + 1);1H" + vtRow(cells)
        }
        let modes = term.modes
        let flags: [(Bool, String)] = [
            (modes.cursorKeysApplication, "\u{1b}[?1h"), (modes.keypadApplication, "\u{1b}="),
            (modes.bracketedPaste, "\u{1b}[?2004h"), (modes.focusReporting, "\u{1b}[?1004h"),
            (modes.mouseClick, "\u{1b}[?1000h"), (modes.mouseDrag, "\u{1b}[?1002h"),
            (modes.mouseAny, "\u{1b}[?1003h"), (modes.mouseSGR, "\u{1b}[?1006h"),
        ]
        for (on, sequence) in flags where on { out += sequence }
        if modes.kittyKeyboardFlags != 0 { out += "\u{1b}[>\(modes.kittyKeyboardFlags)u" }
        out += "\u{1b}[\(grid.cursor.row + 1);\(grid.cursor.col + 1)H"
        if !grid.cursor.visible { out += "\u{1b}[?25l" }
        return Data(out.utf8)
    }

    private static func vtRow(_ cells: [TerminalGridCell]) -> String {
        var out = ""
        var previous = ""
        for cell in cells where cell.width != .spacerTail {
            let style = sgrCodes(cell)
            if style != previous {
                // Every change starts from a reset, so dropping an attribute is never missed.
                out += style.isEmpty ? "\u{1b}[0m" : "\u{1b}[0;\(style)m"
                previous = style
            }
            out += cell.codepoint == 0 ? " " : cell.cluster
        }
        if !previous.isEmpty { out += "\u{1b}[0m" }
        return out
    }

    private static func sgrCodes(_ cell: TerminalGridCell) -> String {
        var codes: [String] = []
        if cell.bold { codes.append("1") }
        if cell.faint { codes.append("2") }
        if cell.italic { codes.append("3") }
        switch cell.underline {
        case .none: break
        case .single: codes.append("4")
        case .double: codes.append("4:2")
        case .curly: codes.append("4:3")
        case .dotted: codes.append("4:4")
        case .dashed: codes.append("4:5")
        }
        if cell.blink { codes.append("5") }
        if cell.inverse { codes.append("7") }
        if cell.invisible { codes.append("8") }
        if cell.strikethrough { codes.append("9") }
        if cell.overline { codes.append("53") }
        if let code = sgrColor(cell.foreground, foreground: true) { codes.append(code) }
        if let code = sgrColor(cell.background, foreground: false) { codes.append(code) }
        if case let .rgb(r, g, b) = cell.underlineColor { codes.append("58;2;\(r);\(g);\(b)") }
        if case let .palette(index) = cell.underlineColor { codes.append("58;5;\(index)") }
        return codes.joined(separator: ";")
    }

    private static func sgrColor(_ color: TerminalGridColor, foreground: Bool) -> String? {
        switch color {
        case .none:
            return nil
        case let .palette(index):
            if index < 8 { return String((foreground ? 30 : 40) + Int(index)) }
            if index < 16 { return String((foreground ? 90 : 100) + Int(index - 8)) }
            return (foreground ? "38;5;" : "48;5;") + String(index)
        case let .rgb(r, g, b):
            return (foreground ? "38;2;" : "48;2;") + "\(r);\(g);\(b)"
        }
    }

    private static func css(_ color: TerminalGridColor) -> String? {
        switch color {
        case .none:
            return nil
        case let .palette(index):
            let rgb = ansi[Int(index) % ansi.count]
            return String(format: "#%02x%02x%02x", rgb.0, rgb.1, rgb.2)
        case let .rgb(r, g, b):
            return String(format: "#%02x%02x%02x", r, g, b)
        }
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let ansi: [(UInt8, UInt8, UInt8)] = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
        (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]
}
