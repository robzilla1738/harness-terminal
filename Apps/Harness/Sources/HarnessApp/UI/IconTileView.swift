import AppKit
import HarnessCore

/// Flat, rectangular app badges with crisp marks and no shadow or animation.
@MainActor
final class IconTileView: NSView {
    enum Content: Equatable {
        case terminal
        case agent(AgentKind)
    }

    private let face = CALayer()
    private let glyph = NSImageView()
    private let prompt = NSTextField(labelWithString: ">_")
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

        prompt.font = .monospacedSystemFont(ofSize: size.height * 0.5, weight: .semibold)
        prompt.alignment = .center
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(prompt)
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
        face.cornerRadius = 5
        let markScale: CGFloat
        switch content {
        case .agent(.crush): markScale = 1
        case .agent(.amp), .agent(.vibe), .agent(.openhands): markScale = 0.9
        default: markScale = 0.76
        }
        let markSide = (faceRect.height * markScale).rounded()
        glyph.frame = NSRect(x: faceRect.midX - markSide / 2, y: faceRect.midY - markSide / 2, width: markSide, height: markSide)
        let textSize = prompt.intrinsicContentSize
        prompt.frame = NSRect(x: faceRect.midX - textSize.width / 2, y: faceRect.midY - textSize.height / 2, width: textSize.width, height: textSize.height)
        CATransaction.commit()
    }

    func apply(_ content: Content) {
        if self.content != content { needsLayout = true }
        self.content = content
        let base: NSColor
        switch content {
        case .terminal:
            base = NSColor.fromHex("#323A3D")!
            prompt.isHidden = false
            prompt.textColor = NSColor.fromHex("#A5D7A1")
            glyph.isHidden = true
        case let .agent(kind):
            base = Self.faceColor(for: kind)
            prompt.isHidden = true
            glyph.isHidden = false
            glyph.image = AgentIconRenderer.templateOrMonogramImage(for: kind, size: badgeSize.height)
            glyph.contentTintColor = glyph.image?.isTemplate == true ? NSColor(white: 0.98, alpha: 1) : nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.backgroundColor = base.cgColor
        face.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        CATransaction.commit()
    }

    func applyChrome() { apply(content) }

    private static func faceColor(for kind: AgentKind) -> NSColor {
        let hex: String
        switch kind {
        case .codex: hex = "#35695B"
        case .claudeCode: hex = "#C96F51"
        case .cursor: hex = "#454B57"
        case .grok: hex = "#3D5367"
        case .pi: hex = "#7963A6"
        case .hermes: hex = "#A87541"
        case .openClaw: hex = "#BC5E50"
        case .openCode: hex = "#437E87"
        case .aider: hex = "#4B8065"
        case .gemini: hex = "#5B77BB"
        case .goose: hex = "#A98137"
        case .copilot: hex = "#7C74D4"
        case .cline: hex = "#697585"
        case .kilo: hex = "#8A7B36"
        case .qwen: hex = "#7563BE"
        case .amp: hex = "#53725B"
        case .droid: hex = "#AC6541"
        case .crush: hex = "#9B438F"
        case .kiro: hex = "#7545B1"
        case .vibe: hex = "#AB6034"
        case .openhands: hex = "#996237"
        case .auggie: hex = "#556FA1"
        case .kimi: hex = "#4D67B3"
        case .generic: hex = "#636B78"
        }
        return NSColor.fromHex(hex)!
    }

    static func content(for agent: AgentKind?) -> Content {
        agent.map(Content.agent) ?? .terminal
    }
}
