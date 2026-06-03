import AppKit

/// Hairline stroke around the entire window edge (Ghostty's faint perimeter border) so the
/// window stands out from same-tone backgrounds. A click-through overlay pinned over the root
/// contentView, stroking a rounded rect that follows the window's live corner radius (squared
/// automatically in fullscreen). Color/opacity come from settings via
/// `MainWindowController.applyTransparency`. The root contentView stays non-layer-backed —
/// this subview is its own layer island, which the blur invariant explicitly allows.
@MainActor
final class WindowBorderOverlayView: NSView {
    private var color: NSColor = .white
    private var opacity: CGFloat = 0

    func update(color: NSColor, opacity: CGFloat) {
        self.color = color
        self.opacity = max(0, min(1, opacity))
        isHidden = self.opacity <= 0.001
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true // the stroke path depends on bounds
    }

    /// The system's live rounding for this window, read from the frame view's layer so the
    /// stroke hugs the real corner on every macOS version (and goes square in fullscreen).
    private var windowCornerRadius: CGFloat {
        if let radius = window?.contentView?.superview?.layer?.cornerRadius, radius > 0 {
            return radius
        }
        return 10 // titled-window default when the frame view exposes none
    }

    override func draw(_ dirtyRect: NSRect) {
        guard opacity > 0.001 else { return }
        // One device pixel, half-inset so the hairline sits crisply on the window edge.
        let scale = window?.backingScaleFactor ?? 2
        let lineWidth = 1 / scale
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = max(0, windowCornerRadius - lineWidth / 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        path.lineWidth = lineWidth
        color.withAlphaComponent(opacity).setStroke()
        path.stroke()
    }

    // Purely decorative — never intercept clicks or hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
