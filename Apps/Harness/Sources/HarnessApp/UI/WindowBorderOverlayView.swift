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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.cornerCurve = .continuous
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
        layer.contentsScale = scale
        layer.cornerCurve = .continuous
        layer.cornerRadius = windowCornerRadius
        // One device pixel, hugging the window edge. The CALayer border is drawn inside the
        // bounds along the rounded path, so with the true radius it sits exactly on the visible
        // corner instead of being clipped by the window mask.
        layer.borderWidth = opacity > 0.001 ? 1 / scale : 0
        layer.borderColor = color.withAlphaComponent(opacity).cgColor
    }

    // Purely decorative — never intercept clicks or hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
