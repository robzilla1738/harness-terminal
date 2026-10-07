import AppKit
import HarnessCore

/// Small rounded tile that leads every tab, sidebar row, and pane header: a dark `>_`
/// tile for a plain shell, or the agent's brand color with its white mark.
@MainActor
final class IconTileView: NSView {
    enum Content: Equatable {
        case terminal
        case agent(AgentKind)
    }

    private let glyph = NSImageView()
    private let prompt = NSTextField(labelWithString: ">_")
    private(set) var content: Content = .terminal
    private let side: CGFloat

    init(side: CGFloat = HarnessDesign.iconTileSize) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.pill
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        prompt.font = .monospacedSystemFont(ofSize: side * 0.42, weight: .bold)
        prompt.alignment = .center
        prompt.translatesAutoresizingMaskIntoConstraints = false
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(prompt)
        addSubview(glyph)
        let inset = side * 0.2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            prompt.centerXAnchor.constraint(equalTo: centerXAnchor),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            glyph.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        setAccessibilityElement(false)
        apply(.terminal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    func apply(_ content: Content) {
        self.content = content
        let c = HarnessChrome.current
        switch content {
        case .terminal:
            prompt.isHidden = false
            glyph.isHidden = true
            layer?.backgroundColor = c.iconTileFill.cgColor
            layer?.borderColor = c.border.cgColor
            prompt.textColor = c.success
        case let .agent(kind):
            prompt.isHidden = true
            glyph.isHidden = false
            let brand = NSColor.fromHex(SessionCoordinator.shared.settings.agentColorHex(for: kind)) ?? c.accent
            layer?.backgroundColor = brand.cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            glyph.image = AgentIconRenderer.templateOrMonogramImage(for: kind, size: side)
            glyph.contentTintColor = .white
        }
    }

    /// Re-read palette colors after a theme change.
    func applyChrome() { apply(content) }

    static func content(for agent: AgentKind?) -> Content {
        agent.map(Content.agent) ?? .terminal
    }
}
