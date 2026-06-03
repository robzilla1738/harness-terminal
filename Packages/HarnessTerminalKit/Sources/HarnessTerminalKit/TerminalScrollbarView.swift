import AppKit

/// Minimal auto-hiding scrollbar shown while scrolling through scrollback. Lives as a sibling
/// above the Metal surface in `TerminalHostView` (the surface is layer-hosting and can't take
/// subviews); it never touches the render pipeline. A thin rounded thumb on the right edge that
/// snaps visible on each scroll tick and fades out shortly after scrolling settles — the same
/// debounced-fade shape as `ResizeHUDView`. Purely decorative: click-through, no track chrome.
final class TerminalScrollbarView: NSView {
    /// Track geometry, in fractions of the scrollable range. `progress` is the thumb position
    /// from top (0 = scrolled to the very top of history, 1 = at the live bottom); `heightFraction`
    /// is the visible viewport as a fraction of the total buffer (thumb size).
    private var progress: CGFloat = 1
    private var heightFraction: CGFloat = 1
    private var hideWork: DispatchWorkItem?
    private var thumbColor = NSColor.labelColor

    /// Thin and unobtrusive — a few points of thumb hugging the right edge.
    private let thumbWidth: CGFloat = 3
    private let edgeInset: CGFloat = 3
    private let trackInsetY: CGFloat = 3
    private let minThumbHeight: CGFloat = 28
    private let cornerRadius: CGFloat = 1.5

    /// Fixed-width vertical strip; the host pins it to the trailing edge full-height.
    static let stripWidth: CGFloat = 9

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Flipped so thumb math is top-down (line 0 at the top of the buffer).
    override var isFlipped: Bool { true }

    /// Theme the thumb to the canvas foreground (legible on any background, like the other overlays).
    func applyColor(_ color: NSColor) {
        thumbColor = color
        needsDisplay = true
    }

    /// Update the thumb from the scroll state and (re)arm the debounced fade-out. Each call cancels
    /// the prior fade, so continuous scrolling keeps it solid and it fades once scrolling settles.
    /// No-op (and hidden) when the whole buffer fits — nothing to scroll.
    func show(topLine: Int, totalLines: Int, visibleRows: Int, fadeOutAfter: TimeInterval = 0.9) {
        guard totalLines > visibleRows, visibleRows > 0 else { hideNow(); return }
        let scrollable = CGFloat(totalLines - visibleRows)
        progress = max(0, min(1, CGFloat(topLine) / scrollable))
        heightFraction = max(0, min(1, CGFloat(visibleRows) / CGFloat(totalLines)))

        hideWork?.cancel()
        isHidden = false
        alphaValue = 1 // snap visible — scrolling updates continuously, no fade-in mid-gesture
        needsDisplay = true

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    // A new show() during the fade re-snaps alpha to 1; don't hide it then.
                    guard let self, self.alphaValue == 0 else { return }
                    self.isHidden = true
                }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutAfter, execute: work)
    }

    func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        isHidden = true
        alphaValue = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let trackHeight = bounds.height - trackInsetY * 2
        guard trackHeight > 0 else { return }
        let thumbHeight = max(minThumbHeight, heightFraction * trackHeight)
        let available = max(0, trackHeight - thumbHeight)
        let y = trackInsetY + progress * available
        let x = bounds.width - thumbWidth - edgeInset
        let rect = NSRect(x: x, y: y, width: thumbWidth, height: thumbHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
        thumbColor.withAlphaComponent(0.45).setFill()
        path.fill()
    }

    // Purely decorative — never intercept clicks or hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
