import AppKit

/// Hairline border around the entire window edge (Ghostty's faint perimeter border) so the
/// window stands out from same-tone backgrounds. A click-through overlay pinned over the root
/// contentView, drawn as a CALayer border that follows the window's live corner radius and the
/// system's continuous (squircle) curve — so it hugs the real corner instead of dropping out
/// there (squared automatically in fullscreen, where the radius reads 0). Color/opacity come from
/// settings via `MainWindowController.applyTransparency`. The root contentView stays
/// non-layer-backed — this subview is its own layer island, which the blur invariant allows.
@MainActor
final class WindowBorderOverlayView: NSView {
    private var color: NSColor = .white
    private var opacity: CGFloat = 0
    /// The stroke lives on its own layer, inset from the window edge. A border
    /// centered on the content edge loses its outer half to the window squircle,
    /// so the corner looks thinner than the straight sides.
    private let strokeLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        installStroke()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        installStroke()
    }

    private func installStroke() {
        // Resize must not animate the stroke independently of the window.
        strokeLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "cornerRadius": NSNull(),
            "borderWidth": NSNull(),
            "borderColor": NSNull(),
        ]
        layer?.addSublayer(strokeLayer)
    }

    func update(color: NSColor, opacity: CGFloat) {
        self.color = color
        self.opacity = max(0, min(1, opacity))
        isHidden = self.opacity <= 0.001
        applyBorder()
    }

    override func layout() {
        super.layout()
        applyBorder() // the corner radius and pixel snapping depend on bounds + scale
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBorder() // backing scale changed (moved to a display with a different scale)
    }

    /// The window's true outer corner radius. macOS rounds the window in the window server, not via
    /// `layer.cornerRadius` (which reads 0 on the frame view), so the authoritative value is
    /// `NSThemeFrame.cornerRadius` — 16 on Tahoe, 0 in fullscreen. Read it via guarded KVC (Harness
    /// is notarized, not App Store, so the private read is fine) and fall back through the layer and
    /// a sane default if a future OS drops the property, so the border degrades instead of vanishing.
    private var windowCornerRadius: CGFloat {
        guard let frameView = window?.contentView?.superview else { return 0 }
        if frameView.responds(to: NSSelectorFromString("cornerRadius")),
           let value = frameView.value(forKey: "cornerRadius") as? NSNumber {
            return CGFloat(value.doubleValue) // authoritative, including 0 in fullscreen
        }
        if let radius = frameView.layer?.cornerRadius, radius > 0 {
            return radius
        }
        return 10 // titled-window default when the frame view exposes nothing
    }

    private func applyBorder() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let line = 1 / scale
        // Sit one device pixel inside the window mask. The stroke is centered on
        // that inset rect, so none of it is clipped, and the radius shrinks by
        // the same amount so the curve stays parallel to the window corner.
        let inset = line
        let radius = max(0, windowCornerRadius - inset)
        layer.contentsScale = scale
        layer.borderWidth = 0
        layer.backgroundColor = nil
        strokeLayer.contentsScale = scale
        strokeLayer.cornerCurve = .continuous
        strokeLayer.frame = bounds.insetBy(dx: inset, dy: inset)
        strokeLayer.cornerRadius = radius
        strokeLayer.borderWidth = opacity > 0.001 ? line : 0
        strokeLayer.borderColor = color.withAlphaComponent(opacity).cgColor
        strokeLayer.backgroundColor = nil
    }

    // Purely decorative — never intercept clicks or hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
