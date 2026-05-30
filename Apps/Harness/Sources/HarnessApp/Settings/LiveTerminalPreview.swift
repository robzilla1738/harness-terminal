import AppKit

/// A restrained, theme-true "this is your terminal" tile at the top of the Appearance
/// page. It renders a real-looking Harness pane using the live settings — the actual
/// canvas (background × opacity, foreground, cursor, selection, bold) and a couple of
/// palette-colored tokens — over a faint monochrome wash so opacity still reads. No gaudy
/// desktop blobs, traffic-light dots, or rainbow swatch strip: it should look like a clean
/// pane, not a color board. Repaints on every settings change.
@MainActor
final class LiveTerminalPreview: NSView {
    enum CursorStyle { case block, beam, underline }

    struct State {
        var colors: ColorSamplePreview.Context
        var palette: [NSColor]
        var fontName: String
        var fontSize: CGFloat
        var opacity: CGFloat
        var blur: CGFloat = 0
        var cursorStyle: CursorStyle
        var cursorBlink: Bool
        var padding: CGFloat = 12
    }

    private var state: State = {
        let c = HarnessChrome.current
        return State(
            colors: .init(
                background: c.terminalBackground, foreground: c.textPrimary, cursor: c.accent,
                cursorText: c.terminalBackground, selectionBackground: c.textPrimary.withAlphaComponent(0.25),
                selectionForeground: c.textPrimary, bold: c.textPrimary
            ),
            palette: Array(repeating: c.textSecondary, count: 16),
            fontName: "Menlo", fontSize: 13, opacity: 1,
            cursorStyle: .block, cursorBlink: false
        )
    }()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = HarnessChrome.current.border.cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 168).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ state: State) {
        self.state = state
        layer?.borderColor = HarnessChrome.current.border.cgColor
        needsDisplay = true
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let chrome = HarnessChrome.current

        // Faint monochrome wash "behind" the pane so dialing opacity down reveals a
        // neutral, theme-derived backdrop (not a colorful desktop). Two close tones.
        if let gradient = NSGradient(colors: [
            chrome.surfaceElevated.blended(withFraction: 0.5, of: chrome.sidebarBackground) ?? chrome.sidebarBackground,
            chrome.sidebarBackground,
        ]) {
            gradient.draw(in: rect, angle: 90)
        }

        // Terminal background × opacity — the real translucency.
        state.colors.background.withAlphaComponent(state.opacity).setFill()
        ctx.fill(rect)

        // Minimal header: a slim bar + 1px divider, no traffic lights.
        let headerHeight: CGFloat = 14
        state.colors.foreground.withAlphaComponent(0.05).setFill()
        ctx.fill(NSRect(x: 0, y: 0, width: rect.width, height: headerHeight))
        state.colors.foreground.withAlphaComponent(0.10).setFill()
        ctx.fill(NSRect(x: 0, y: headerHeight, width: rect.width, height: 1))

        // Body, inset by the live window padding (scaled so the preview reads true).
        let inset = max(12, min(28, state.padding))
        let left = inset
        let bodyTop = headerHeight + max(10, inset * 0.6)
        let baseFont = NSFont(name: state.fontName, size: state.fontSize)
            ?? .monospacedSystemFont(ofSize: state.fontSize, weight: .regular)
        let boldFont = bestBoldFont(name: state.fontName, size: state.fontSize)
        let lineHeight = state.fontSize + 7

        let prompt = state.palette.indices.contains(2) ? state.palette[2] : state.colors.foreground
        let pathColor = state.palette.indices.contains(4) ? state.palette[4] : state.colors.foreground
        let added = state.palette.indices.contains(2) ? state.palette[2] : state.colors.foreground
        let removed = state.palette.indices.contains(1) ? state.palette[1] : state.colors.foreground
        let dim = state.colors.foreground.withAlphaComponent(0.72)

        // Line 1: prompt + path + command.
        let y1 = bodyTop
        var x = left
        x = draw("➜ ", at: NSPoint(x: x, y: y1), color: prompt, font: baseFont)
        x = draw("~/code/harness ", at: NSPoint(x: x, y: y1), color: pathColor, font: baseFont)
        _ = draw("git status", at: NSPoint(x: x, y: y1), color: state.colors.foreground, font: baseFont)

        // Line 2: branch output with the bold color.
        let y2 = y1 + lineHeight
        var x2 = left
        x2 = draw("On branch ", at: NSPoint(x: x2, y: y2), color: dim, font: baseFont)
        _ = draw("main", at: NSPoint(x: x2, y: y2), color: state.colors.bold, font: boldFont)

        // Line 3: a diff-style line so palette edits (green/red) still read.
        let y3 = y2 + lineHeight
        var x3 = left
        x3 = draw("  ", at: NSPoint(x: x3, y: y3), color: dim, font: baseFont)
        x3 = draw("+ added.swift  ", at: NSPoint(x: x3, y: y3), color: added, font: baseFont)
        _ = draw("- removed.swift", at: NSPoint(x: x3, y: y3), color: removed, font: baseFont)

        // Line 4: a selection sample.
        let y4 = y3 + lineHeight
        var x4 = left
        x4 = draw("➜ ", at: NSPoint(x: x4, y: y4), color: prompt, font: baseFont)
        let sel = NSAttributedString(string: "selected text", attributes: [
            .foregroundColor: state.colors.selectionForeground, .font: baseFont,
        ])
        let selSize = sel.size()
        let selRect = NSRect(x: x4 - 1, y: y4 - 1, width: selSize.width + 4, height: lineHeight - 2)
        state.colors.selectionBackground.setFill()
        NSBezierPath(roundedRect: selRect, xRadius: 3, yRadius: 3).fill()
        sel.draw(at: NSPoint(x: x4 + 1, y: y4))

        // Line 5: prompt + cursor sample.
        let y5 = y4 + lineHeight
        var x5 = left
        x5 = draw("➜ ", at: NSPoint(x: x5, y: y5), color: prompt, font: baseFont)
        drawCursor(at: NSPoint(x: x5, y: y5), font: baseFont)
    }

    @discardableResult
    private func draw(_ s: String, at p: NSPoint, color: NSColor, font: NSFont) -> CGFloat {
        let attr = NSAttributedString(string: s, attributes: [.foregroundColor: color, .font: font])
        attr.draw(at: p)
        return p.x + attr.size().width
    }

    private func drawCursor(at p: NSPoint, font: NSFont) {
        let advance: CGFloat = font.maximumAdvancement.width.isFinite ? font.maximumAdvancement.width : font.pointSize * 0.6
        let height = font.pointSize + 2
        switch state.cursorStyle {
        case .block:
            let rect = NSRect(x: p.x, y: p.y, width: advance, height: height)
            state.colors.cursor.setFill()
            rect.fill()
        case .beam:
            state.colors.cursor.setFill()
            NSRect(x: p.x, y: p.y, width: 2, height: height).fill()
        case .underline:
            state.colors.cursor.setFill()
            NSRect(x: p.x, y: p.y + height - 2, width: advance, height: 2).fill()
        }
    }

    private func bestBoldFont(name: String, size: CGFloat) -> NSFont {
        if let bold = NSFont(name: name + "-Bold", size: size) { return bold }
        if let descriptor = NSFont(name: name, size: size)?.fontDescriptor.withSymbolicTraits(.bold),
           let bold = NSFont(descriptor: descriptor, size: size) { return bold }
        return .monospacedSystemFont(ofSize: size, weight: .bold)
    }
}
