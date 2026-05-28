import AppKit

/// Big "this is what your terminal looks like right now" tile shown at the top
/// of the Appearance page. Renders a faux Harness window using the live
/// settings — background tint × opacity, foreground, cursor, selection, bold,
/// and the 16-slot ANSI palette across the bottom. Repaints on every
/// slider/field/well change so the user sees their edit immediately.
@MainActor
final class LiveTerminalPreview: NSView {
    enum CursorStyle { case block, beam, underline }

    struct State {
        var colors: ColorSamplePreview.Context
        var palette: [NSColor]
        var fontName: String
        var fontSize: CGFloat
        var opacity: CGFloat
        var cursorStyle: CursorStyle
        var cursorBlink: Bool
    }

    private var state: State = .init(
        colors: .init(
            background: .black, foreground: .white, cursor: .systemBlue,
            cursorText: .black, selectionBackground: NSColor.systemBlue.withAlphaComponent(0.4),
            selectionForeground: .white, bold: .white
        ),
        palette: Array(repeating: .gray, count: 16),
        fontName: "Menlo",
        fontSize: 13,
        opacity: 1,
        cursorStyle: .block,
        cursorBlink: false
    )

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        // A fixed-ish aspect ratio so it always reads as a tiny window.
        heightAnchor.constraint(equalToConstant: 188).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ state: State) {
        self.state = state
        needsDisplay = true
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds

        // Background — tinted bg × opacity, so dialing opacity down visibly fades the tile.
        let bg = state.colors.background.withAlphaComponent(state.opacity)
        bg.setFill()
        ctx.fill(rect)

        // Title bar — three traffic-light dots and a faint divider, so the tile
        // reads as a real window rather than a flat colored card.
        let titlebarHeight: CGFloat = 22
        let titlebar = NSRect(x: 0, y: 0, width: rect.width, height: titlebarHeight)
        NSColor.black.withAlphaComponent(0.18).setFill()
        ctx.fill(titlebar)
        let dotColors: [NSColor] = [
            NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1),
            NSColor(srgbRed: 0.99, green: 0.74, blue: 0.16, alpha: 1),
            NSColor(srgbRed: 0.18, green: 0.79, blue: 0.27, alpha: 1),
        ]
        for (i, color) in dotColors.enumerated() {
            color.setFill()
            let dot = NSRect(x: 10 + CGFloat(i) * 16, y: titlebar.midY - 5, width: 10, height: 10)
            NSBezierPath(ovalIn: dot).fill()
        }
        NSColor.black.withAlphaComponent(0.25).setFill()
        ctx.fill(NSRect(x: 0, y: titlebarHeight - 1, width: rect.width, height: 1))

        // Body — sample prompt + a couple of lines + a selection highlight + cursor.
        let bodyTop = titlebarHeight + 14
        let lineHeight = state.fontSize + 6
        let baseFont = NSFont(name: state.fontName, size: state.fontSize)
            ?? .monospacedSystemFont(ofSize: state.fontSize, weight: .regular)
        let boldFont = bestBoldFont(name: state.fontName, size: state.fontSize)

        let promptColor = state.palette.indices.contains(2) ? state.palette[2] : state.colors.foreground
        let pathColor = state.palette.indices.contains(4) ? state.palette[4] : state.colors.foreground
        let dim = state.colors.foreground.withAlphaComponent(0.78)

        // Line 1: prompt with bold result word
        var x: CGFloat = 14
        let line1Y = bodyTop
        x = draw("➜  ", at: NSPoint(x: x, y: line1Y), color: promptColor, font: baseFont)
        x = draw("~/code/harness ", at: NSPoint(x: x, y: line1Y), color: pathColor, font: baseFont)
        x = draw("git status", at: NSPoint(x: x, y: line1Y), color: state.colors.foreground, font: baseFont)

        // Line 2: a "branch" output with the bold color highlighted
        let line2Y = line1Y + lineHeight
        var x2: CGFloat = 14
        x2 = draw("On branch ", at: NSPoint(x: x2, y: line2Y), color: dim, font: baseFont)
        x2 = draw("main", at: NSPoint(x: x2, y: line2Y), color: state.colors.bold, font: boldFont)

        // Line 3: prompt + the selection sample
        let line3Y = line2Y + lineHeight
        var x3: CGFloat = 14
        x3 = draw("➜  ", at: NSPoint(x: x3, y: line3Y), color: promptColor, font: baseFont)
        let sel = NSAttributedString(string: "selected text", attributes: [
            .foregroundColor: state.colors.selectionForeground,
            .font: baseFont,
        ])
        let selSize = sel.size()
        let selRect = NSRect(x: x3 - 1, y: line3Y - 1, width: selSize.width + 4, height: lineHeight - 2)
        state.colors.selectionBackground.setFill()
        NSBezierPath(roundedRect: selRect, xRadius: 2, yRadius: 2).fill()
        sel.draw(at: NSPoint(x: x3 + 1, y: line3Y))
        x3 += selSize.width + 8

        // Line 4: prompt + cursor sample
        let line4Y = line3Y + lineHeight
        var x4: CGFloat = 14
        x4 = draw("➜  ", at: NSPoint(x: x4, y: line4Y), color: promptColor, font: baseFont)
        drawCursor(at: NSPoint(x: x4, y: line4Y), font: baseFont)

        // ANSI palette strip across the bottom — small color chips so theme/palette
        // changes show up in the same tile (no need to flip pages to see effect).
        let stripHeight: CGFloat = 14
        let stripY = rect.height - stripHeight - 8
        let chipCount: CGFloat = 16
        let chipWidth = (rect.width - 28) / chipCount
        for (i, color) in state.palette.prefix(16).enumerated() {
            let chip = NSRect(
                x: 14 + CGFloat(i) * chipWidth,
                y: stripY,
                width: chipWidth - 1,
                height: stripHeight
            )
            color.setFill()
            NSBezierPath(roundedRect: chip, xRadius: 2, yRadius: 2).fill()
        }
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
        let rect: NSRect
        switch state.cursorStyle {
        case .block:
            rect = NSRect(x: p.x, y: p.y, width: advance, height: height)
            state.colors.cursor.setFill()
            rect.fill()
            let glyph = NSAttributedString(string: "_", attributes: [
                .foregroundColor: state.colors.cursorText,
                .font: font,
            ])
            glyph.draw(at: NSPoint(x: p.x + 1, y: p.y))
        case .beam:
            rect = NSRect(x: p.x, y: p.y, width: 2, height: height)
            state.colors.cursor.setFill()
            rect.fill()
        case .underline:
            rect = NSRect(x: p.x, y: p.y + height - 2, width: advance, height: 2)
            state.colors.cursor.setFill()
            rect.fill()
        }
    }

    private func bestBoldFont(name: String, size: CGFloat) -> NSFont {
        if let bold = NSFont(name: name + "-Bold", size: size) { return bold }
        if let descriptor = NSFont(name: name, size: size)?.fontDescriptor
            .withSymbolicTraits(.bold),
            let bold = NSFont(descriptor: descriptor, size: size)
        { return bold }
        return .monospacedSystemFont(ofSize: size, weight: .bold)
    }
}
