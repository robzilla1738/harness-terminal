import AppKit

/// Transient "120 × 32" overlay shown while the window/grid is being resized (Ghostty's resize
/// overlay). Lives as a sibling above the Metal surface in `TerminalHostView`; it never touches
/// the render pipeline. Auto-hides via a debounced fade so a continuous drag keeps it solid and
/// it fades shortly after the size settles — the same debounce shape as the grid resize commit.
final class ResizeHUDView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        alphaValue = 0

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Legibility trick (matches the pane-border label / copy-mode status): a translucent fill in
    /// the canvas foreground color with background-colored text, so it reads on any theme.
    func applyColors(text: NSColor, fill: NSColor) {
        label.textColor = text
        layer?.backgroundColor = fill.withAlphaComponent(0.82).cgColor
    }

    /// Show the current grid size and (re)arm the debounced fade-out. Each call cancels the prior
    /// fade, so during a continuous drag the overlay stays solid and only fades once the size
    /// settles.
    func show(cols: Int, rows: Int, fadeOutAfter: TimeInterval = 0.6) {
        label.stringValue = "\(cols) × \(rows)"
        hideWork?.cancel()
        isHidden = false
        alphaValue = 1 // snap visible — a resize updates continuously, no fade-in mid-drag
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
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

    // Purely decorative — never intercept clicks or hover.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
