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

        for label in [leftLabel, rightLabel, centerLabel] {
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
        NSLayoutConstraint.activate([
            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leftLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftLabel.trailingAnchor.constraint(lessThanOrEqualTo: centerLabel.leadingAnchor, constant: -8),

            centerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLabel.leadingAnchor.constraint(greaterThanOrEqualTo: centerLabel.trailingAnchor, constant: 8),

            // 26pt keeps the baseline well above the window's rounded bottom
            // corner so text reads as a defined footer rather than a strip
            // floating into the corner curve.
            heightAnchor.constraint(equalToConstant: 26),
        ])
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
        let visible = options.get("status", scope: .global)?.boolValue ?? true
        isHidden = !visible
        guard visible else { return }
        let context = buildContext()
        leftLabel.attributedStringValue = styledAttributed(options.get("status-left", scope: .global)?.stringValue ?? "", context: context)
        rightLabel.attributedStringValue = styledAttributed(options.get("status-right", scope: .global)?.stringValue ?? "", context: context, alignment: .right)
        centerLabel.attributedStringValue = styledAttributed(options.get("status-center", scope: .global)?.stringValue ?? "", context: context, alignment: .center)
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
    static let shared = OptionStore()
}
