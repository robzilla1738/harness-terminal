import Foundation

/// Renders the one-shot first-run / post-update banners as raw terminal output —
/// SGR-styled, `\r\n` line endings — for injection into a surface's output stream
/// (`RealPty.injectSyntheticOutput`). The bytes travel the same path as PTY reads,
/// so the banner lands in scrollback, replays on reattach, and scrolls away like a
/// login MOTD. Pure string assembly: no AppKit, Linux-safe.
///
/// Width contract: surfaces spawn at the 24×80 placeholder size before any client
/// resize vote, so the box is capped at `maxInnerWidth` + frame ≤ 64 columns and the
/// rendered lines never wrap at spawn width.
public enum TerminalBanner {
    // MARK: - Entry points

    /// The first-run tour. Hand-holding by design: what makes Harness different, then a
    /// numbered list of things to try in order. Body copy is word-wrapped to the pane —
    /// never truncated — so the tour reads whole at any width.
    public static func welcome(version: String, columns: Int) -> Data {
        let inner = innerWidth(columns: columns)
        var lines: [[Run]] = []
        lines.append([Run("⌁ ", sgr: accent), Run("Welcome to Harness \(version)", sgr: bold)])
        lines += wrappedText("The native terminal with a multiplexer built in.", sgr: dim, inner: inner)
        lines.append([])
        lines.append([Run("Why it's different", sgr: bold)])
        let bullets = [
            "GPU-native renderer — pixel-smooth output and 25 original Harness themes alongside community favorites",
            "Your shells outlive the window — a background daemon keeps every session running across closes and restarts",
            "tmux workflows, no tmux — tabs, splits, prefix keys, copy mode, scriptable from harness-cli",
            "Agent-aware — Claude Code, Codex & friends show live working / needs-attention status on their tab",
            "Remote-ready — run the daemon on a Linux box or server and attach from here over SSH",
        ]
        for bullet in bullets {
            lines += wrappedBullet(bullet, inner: inner)
        }
        lines.append([])
        lines.append([Run("Try this, in order", sgr: bold)])
        let steps: [(key: String, what: String)] = [
            ("ctrl-a c", "open a second tab"),
            ("ctrl-a %", "split this pane · \" splits across"),
            ("ctrl-a ?", "every keybinding, searchable"),
            ("ctrl-a :", "command prompt · try: rename-window"),
            ("harness-cli ping", "script Harness from any shell"),
        ]
        for (index, step) in steps.enumerated() {
            lines += wrappedStep(number: index + 1, key: step.key, what: step.what, inner: inner)
        }
        lines.append([])
        lines.append([Run("Docs: thebestterminal.com"), Run("  ·  ", sgr: dim), Run("Settings: ⌘,")])
        lines += wrappedText("One-time tour — it won't print again.", sgr: dim, inner: inner)
        return render(lines: lines, columns: columns)
    }

    public static func whatsNew(_ notes: ReleaseNotes, columns: Int) -> Data {
        var lines: [[Run]] = []
        lines.append([Run("⌁ ", sgr: accent), Run("Harness updated · \(notes.version)", sgr: bold)])
        for section in orderedSections(notes.sections) where !section.items.isEmpty {
            lines.append([])
            lines.append([Run(section.title, sgr: bold)])
            for item in section.items.prefix(maxItemsPerSection) {
                lines.append([Run(" • ", sgr: dim), Run(item)])
            }
            let hidden = section.items.count - maxItemsPerSection
            if hidden > 0 {
                lines.append([Run("   … and \(hidden) more", sgr: dim)])
            }
        }
        lines.append([])
        lines.append([Run("Full notes: thebestterminal.com/changelog", sgr: dim)])
        return render(lines: lines, columns: columns)
    }

    // MARK: - Layout

    /// A run of text under one SGR attribute (nil = default pen).
    struct Run {
        let text: String
        let sgr: String?
        init(_ text: String, sgr: String? = nil) {
            self.text = text
            self.sgr = sgr
        }
    }

    private static let bold = "1"
    /// Bright black, not SGR 2 faint — every theme maps the bright-black slot, while
    /// faint support varies across palettes.
    private static let dim = "90"
    private static let accent = "36"
    private static let maxItemsPerSection = 4
    private static let maxInnerWidth = 60
    /// Below this the frame costs more columns than it's worth — render plain lines.
    private static let minBoxColumns = 44

    /// "Added" before "Fixed" reads better in a what's-new card than the repo
    /// changelog's audit-first ordering; unknown titles keep their original position
    /// after the known ones.
    private static func orderedSections(_ sections: [ReleaseNotes.Section]) -> [ReleaseNotes.Section] {
        let rank = ["Added": 0, "Changed": 1, "Fixed": 2, "Deprecated": 3, "Removed": 4, "Security": 5]
        return sections.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.title] ?? 99
            let r = rank[rhs.element.title] ?? 99
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    private static func innerWidth(columns: Int) -> Int {
        columns >= minBoxColumns ? min(columns - 4, maxInnerWidth) : max(columns, 20)
    }

    /// A single-style paragraph wrapped at the box width.
    private static func wrappedText(_ text: String, sgr: String?, inner: Int) -> [[Run]] {
        wrap(text, width: inner).map { [Run($0, sgr: sgr)] }
    }

    /// A bullet whose body wraps at the box width with a hanging indent — the welcome
    /// tour must never truncate (a chopped pitch reads broken, not minimal).
    private static func wrappedBullet(_ text: String, inner: Int) -> [[Run]] {
        wrap(text, width: max(inner - 3, 10)).enumerated().map { index, line in
            index == 0 ? [Run(" • ", sgr: dim), Run(line)] : [Run("   "), Run(line)]
        }
    }

    /// A numbered try-this step: `key` in an aligned accent column, the description
    /// wrapped beside it (or beneath it when the pane is too narrow for two columns).
    private static func wrappedStep(number: Int, key: String, what: String, inner: Int) -> [[Run]] {
        let lead = " \(number)  "
        let keyColumn = 18
        let descWidth = inner - lead.count - keyColumn
        guard descWidth >= 16 else {
            var lines: [[Run]] = [[Run(lead, sgr: dim), Run(key, sgr: accent)]]
            lines += wrap(what, width: max(inner - 5, 10)).map { [Run("     "), Run($0)] }
            return lines
        }
        return wrap(what, width: descWidth).enumerated().map { index, line in
            index == 0
                ? [Run(lead, sgr: dim), Run(pad(key, to: keyColumn), sgr: accent), Run(line)]
                : [Run(String(repeating: " ", count: lead.count + keyColumn)), Run(line)]
        }
    }

    /// Display-width-aware word wrap. A single word longer than `width` is kept whole
    /// (the render-time truncation backstop handles it).
    static func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        var currentWidth = 0
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let wordWidth = displayWidth(String(word))
            if currentWidth == 0 {
                current = String(word)
                currentWidth = wordWidth
            } else if currentWidth + 1 + wordWidth <= width {
                current += " " + word
                currentWidth += 1 + wordWidth
            } else {
                lines.append(current)
                current = String(word)
                currentWidth = wordWidth
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [""] : lines
    }

    private static func render(lines: [[Run]], columns: Int) -> Data {
        let boxed = columns >= minBoxColumns
        let inner = innerWidth(columns: columns)
        var out = "\u{1B}[0m\r\n"
        if boxed {
            out += sgr(dim, "╭" + String(repeating: "─", count: inner + 2) + "╮") + "\r\n"
        }
        for line in lines {
            let (runs, width) = truncate(line, to: inner)
            var text = runs.map { run in run.sgr.map { sgr($0, run.text) } ?? run.text }.joined()
            if boxed {
                text += String(repeating: " ", count: max(0, inner - width))
                text = sgr(dim, "│") + " " + text + " " + sgr(dim, "│")
            }
            out += text + "\r\n"
        }
        if boxed {
            out += sgr(dim, "╰" + String(repeating: "─", count: inner + 2) + "╯") + "\r\n"
        }
        out += "\r\n"
        return Data(out.utf8)
    }

    private static func sgr(_ code: String, _ text: String) -> String {
        "\u{1B}[\(code)m\(text)\u{1B}[0m"
    }

    /// Cut a styled line at `width` display columns, replacing the overflow with `…`.
    private static func truncate(_ line: [Run], to width: Int) -> (runs: [Run], width: Int) {
        let total = line.reduce(0) { $0 + displayWidth($1.text) }
        guard total > width else { return (line, total) }
        var budget = width - 1 // reserve the ellipsis column
        var kept: [Run] = []
        for run in line {
            let runWidth = displayWidth(run.text)
            if runWidth <= budget {
                kept.append(run)
                budget -= runWidth
                continue
            }
            var cut = ""
            for scalar in run.text.unicodeScalars {
                let w = DisplayWidth.width(of: scalar)
                if w > budget { break }
                cut.unicodeScalars.append(scalar)
                budget -= w
            }
            if !cut.isEmpty { kept.append(Run(cut, sgr: run.sgr)) }
            break
        }
        kept.append(Run("…", sgr: dim))
        return (kept, width - budget)
    }

    private static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }

    // MARK: - Display width

    /// Banner box math is display-column aware (changelog items can carry CJK or emoji).
    /// Shares the one core width table with status-format truncation — see `DisplayWidth`.
    static func displayWidth(_ text: String) -> Int {
        DisplayWidth.columns(of: text)
    }
}
