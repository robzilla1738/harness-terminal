import AppKit
import HarnessCore

/// Bottom-of-window status line. Rendered from `OptionStore` keys
/// `status`/`status-left`/`status-right` via `FormatString`. Refreshes on
/// snapshot changes (so cwd/agent updates land instantly) and on a 1s timer
/// (so `#{time:%H:%M}` ticks without polling everything).
@MainActor
final class StatusLineView: NSView {
    private let leftLabel = NSTextField(labelWithString: "")
    private let rightLabel = NSTextField(labelWithString: "")
    private let centerLabel = NSTextField(labelWithString: "")
    /// Full-width rows above the main band for tmux `status 2..5` (`status-format-1…4`).
    /// Pre-created and hidden; `refresh` shows as many as the line count needs.
    private let extraLabels: [NSTextField] = (0..<4).map { _ in NSTextField(labelWithString: "") }
    private var heightConstraint: NSLayoutConstraint!
    private static let mainRowHeight: CGFloat = 26
    private static let extraRowHeight: CGFloat = 22
    private var refreshTimer: Timer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        // The split above ends at `statusLine.topAnchor`, so without our own
        // backdrop this view sits over raw window material — the text reads as
        // floating outside the chrome on translucent windows. Install a
        // sidebar-role backdrop so the status footer is a defined band that
        // matches the chrome directly above it.
        layer?.backgroundColor = NSColor.clear.cgColor
        HarnessDesign.installChromeBackground(.sidebar, on: self)

        for label in [leftLabel, rightLabel, centerLabel] + extraLabels {
            label.translatesAutoresizingMaskIntoConstraints = false
            // 12pt regular reads cleaner than 11pt medium on translucent
            // surfaces — heavier-stem-at-bigger-size gives crisper edges than
            // thin-stem-at-tiny-size on subpixel-blended text.
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.textColor = HarnessChrome.current.textSecondary
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        rightLabel.alignment = .right
        centerLabel.alignment = .center
        for label in extraLabels { label.isHidden = true }

        // The main (left/center/right) row is pinned to the bottom `mainRowHeight`
        // band; extra `status 2..5` rows stack above it. Anchoring the main row to
        // the bottom (not the view centre) keeps its baseline above the window's
        // rounded corner regardless of how many rows are visible.
        let mainCenterY = bottomAnchor.constraint(equalTo: leftLabel.centerYAnchor, constant: Self.mainRowHeight / 2)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.mainRowHeight)
        var constraints: [NSLayoutConstraint] = [
            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mainCenterY,
            leftLabel.trailingAnchor.constraint(lessThanOrEqualTo: centerLabel.leadingAnchor, constant: -8),

            centerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerLabel.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),

            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightLabel.centerYAnchor.constraint(equalTo: leftLabel.centerYAnchor),
            rightLabel.leadingAnchor.constraint(greaterThanOrEqualTo: centerLabel.trailingAnchor, constant: 8),

            heightConstraint,
        ]
        // Extra row i (0-based) sits in the band centred at
        // `mainRowHeight + i*extraRowHeight + extraRowHeight/2` above the bottom.
        for (i, label) in extraLabels.enumerated() {
            let centerOffset = Self.mainRowHeight + CGFloat(i) * Self.extraRowHeight + Self.extraRowHeight / 2
            constraints.append(label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10))
            constraints.append(label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10))
            constraints.append(bottomAnchor.constraint(equalTo: label.centerYAnchor, constant: centerOffset))
        }
        NSLayoutConstraint.activate(constraints)
        applyChrome()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(snapshotChanged),
            name: NotificationBus.shared.snapshotChanged,
            object: nil
        )
        startTimer()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyChrome() {
        // Re-run the backdrop install so it re-reads HarnessChrome.backgroundOpacity.
        // Without this the footer's backdrop stays frozen at the opacity it had when
        // the view was first created — so lowering opacity in Settings left the
        // status bar opaque (solid) while the sidebar/terminal went translucent.
        HarnessDesign.applySidebarChrome(to: self)
        let color = resolvedTextColor()
        for label in [leftLabel, rightLabel, centerLabel] {
            label.textColor = color
        }
        refresh()
    }

    /// User override (`settings.statusLineHex`) wins; otherwise a slightly
    /// brighter blend than `textSecondary` so the status footer holds its own
    /// against a translucent window without losing legibility to subpixel
    /// antialiasing on a non-opaque background.
    private func resolvedTextColor() -> NSColor {
        if let hex = SessionCoordinator.shared.settings.statusLineHex,
           let color = NSColor.fromHex(hex) {
            return color
        }
        let chrome = HarnessChrome.current
        return chrome.textPrimary.withAlphaComponent(chrome.isDark ? 0.78 : 0.72)
    }

    @objc private func snapshotChanged(_ note: Notification) {
        refresh()
    }

    private func startTimer() {
        refreshTimer?.invalidate()
        // 1s tick so `#{time:%H:%M}` updates without us needing per-second
        // snapshot changes. Cheap — just an attributed-string set.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func refresh() {
        let options = HarnessOptions.shared
        // Mode gate first: non-tmux experiences (Plain/Persistent/Agent without tmux controls)
        // never show the status band — it's part of the multiplexer chrome. Within a
        // tmux-chrome experience, the GUI Settings toggle is the hard override; when off the
        // band is hidden regardless of the tmux `status` option. Otherwise `status`
        // (`off`/`on`/`2..5`) drives how many rows show.
        let settings = SessionCoordinator.shared.settings
        let showInSettings = settings.showsTmuxChrome && settings.showStatusLine
        let count = showInSettings ? (options.get("status", scope: .global)?.statusLineCount ?? 1) : 0
        isHidden = count == 0
        guard count > 0 else {
            // Collapse the band to 0 so the terminal split fills the freed space
            // (a hidden view still reserves its height constraint otherwise).
            heightConstraint.constant = 0
            return
        }
        let context = buildContext()
        leftLabel.attributedStringValue = styledAttributed(options.get("status-left", scope: .global)?.stringValue ?? "", context: context)
        rightLabel.attributedStringValue = styledAttributed(options.get("status-right", scope: .global)?.stringValue ?? "", context: context, alignment: .right)
        centerLabel.attributedStringValue = styledAttributed(options.get("status-center", scope: .global)?.stringValue ?? "", context: context, alignment: .center)
        // Extra rows above the main band: `status-format-1` is the first row up, etc.
        for (i, label) in extraLabels.enumerated() {
            let lineIndex = i + 1
            if lineIndex < count {
                label.isHidden = false
                label.attributedStringValue = styledAttributed(options.get("status-format-\(lineIndex)", scope: .global)?.stringValue ?? "", context: context)
            } else {
                label.isHidden = true
                label.attributedStringValue = NSAttributedString()
            }
        }
        heightConstraint.constant = Self.mainRowHeight + CGFloat(max(0, count - 1)) * Self.extraRowHeight
    }

    /// Render a status format to an attributed string, honoring `#[fg=…,bg=…,attrs]` style
    /// spans (the shared `StyledSegment` intermediate the compositor also consumes).
    private func styledAttributed(_ format: String, context: FormatContext, alignment: NSTextAlignment = .left) -> NSAttributedString {
        let def = HarnessChrome.current.textSecondary
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byTruncatingTail
        let out = NSMutableAttributedString()
        for seg in FormatString.evaluateStyled(format, context: context) {
            let fg = seg.fg.map { Self.nsColor($0, default: def) } ?? def
            var attrs: [NSAttributedString.Key: Any] = [.paragraphStyle: para]
            if seg.reverse {
                attrs[.foregroundColor] = seg.bg.map { Self.nsColor($0, default: .clear) } ?? HarnessChrome.current.terminalBackground
                attrs[.backgroundColor] = fg
            } else {
                attrs[.foregroundColor] = fg
                if let bg = seg.bg { attrs[.backgroundColor] = Self.nsColor(bg, default: .clear) }
            }
            var font = NSFont.monospacedSystemFont(ofSize: 12, weight: seg.bold ? .bold : .regular)
            if seg.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            attrs[.font] = font
            if seg.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: seg.text, attributes: attrs))
        }
        return out
    }

    /// Map a `FormatColor` to an `NSColor` via the standard xterm-256 palette.
    private static func nsColor(_ color: FormatColor, default def: NSColor) -> NSColor {
        switch color {
        case .none: return def
        case let .palette(i): return paletteColor(i)
        case let .rgb(r, g, b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    private static let base16: [(Int, Int, Int)] = [
        (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0), (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
        (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0), (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]

    private static func paletteColor(_ index: Int) -> NSColor {
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        if index >= 0, index < 16 { let c = base16[index]; return rgb(c.0, c.1, c.2) }
        if index >= 16, index < 232 {
            let i = index - 16
            func level(_ v: Int) -> Int { v == 0 ? 0 : 55 + v * 40 }
            return rgb(level(i / 36), level((i / 6) % 6), level(i % 6))
        }
        if index >= 232, index < 256 { let v = 8 + (index - 232) * 10; return rgb(v, v, v) }
        return .secondaryLabelColor
    }

    private func buildContext() -> FormatContext {
        SessionCoordinator.shared.currentFormatContext()
    }
}

/// Shared singleton wrapping `OptionStore` for the app process. Keeps callers
/// from constructing a new store every read.
@MainActor
enum HarnessOptions {
    /// The app's mirror of the daemon-owned `options.json`. Reloaded from disk after the
    /// Settings ▸ Advanced page writes an option via IPC so the status line (and other
    /// option readers) reflect the change without an app restart.
    private(set) static var shared = OptionStore()
    static func reloadFromDisk() { shared = OptionStore() }
}
