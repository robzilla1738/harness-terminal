import AppKit
import HarnessCore

/// Uniform monochrome agent marks on transparent faces; terminal tiles retain chrome.
@MainActor
final class IconTileView: NSView {
    enum Content: Equatable {
        case terminal
        case agent(AgentKind)
    }

    private let face = CALayer()
    private let glyph = NSImageView()
    private let prompt = CAShapeLayer()
    private(set) var content: Content = .terminal
    private let badgeSize: NSSize

    init(size: NSSize = HarnessDesign.iconTileSize) {
        badgeSize = size
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        face.cornerCurve = .continuous
        face.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        face.borderWidth = 0.5
        layer?.addSublayer(face)

        prompt.fillColor = nil
        prompt.strokeColor = NSColor.fromHex("#98C794")!.cgColor
        prompt.lineCap = .round
        prompt.lineJoin = .round
        prompt.actions = ["path": NSNull(), "hidden": NSNull()]
        layer?.addSublayer(prompt)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
        setAccessibilityElement(false)
        apply(.terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { badgeSize }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let faceRect = bounds
        face.frame = faceRect
        face.cornerRadius = (faceRect.height * 0.25).rounded()
        let markScale: CGFloat = 0.76
        let markSide = (faceRect.height * markScale).rounded()
        glyph.frame = NSRect(x: faceRect.midX - markSide / 2, y: faceRect.midY - markSide / 2, width: markSide, height: markSide)
        // Draw the prompt as one balanced mark, independent of font metrics.
        let scale = faceRect.height / 16
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -4.5, y: 3))
        path.addLine(to: CGPoint(x: -1, y: 0))
        path.addLine(to: CGPoint(x: -4.5, y: -3))
        path.move(to: CGPoint(x: 1, y: -3))
        path.addLine(to: CGPoint(x: 4.5, y: -3))
        var transform = CGAffineTransform(translationX: faceRect.midX, y: faceRect.midY).scaledBy(x: scale, y: scale)
        prompt.frame = bounds
        prompt.path = path.copy(using: &transform)
        prompt.lineWidth = 1.25 * scale
        prompt.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func apply(_ content: Content) {
        if self.content != content { needsLayout = true }
        self.content = content
        let base: NSColor
        switch content {
        case .terminal:
            base = NSColor.fromHex("#272C2D")!
            prompt.isHidden = false
            glyph.isHidden = true
        case let .agent(kind):
            base = .clear
            prompt.isHidden = true
            glyph.isHidden = false
            glyph.image = AgentIconRenderer.templateOrMonogramImage(for: kind, size: badgeSize.height)
            glyph.contentTintColor = .labelColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.backgroundColor = base.cgColor
        face.borderColor = (content == .terminal ? NSColor.white.withAlphaComponent(0.14) : NSColor.clear).cgColor
        CATransaction.commit()
    }

    func applyChrome() { apply(content) }

    static func content(for agent: AgentKind?) -> Content {
        agent.map(Content.agent) ?? .terminal
    }
}
