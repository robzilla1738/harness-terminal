import AppKit

/// Minimal transient toast — fades in at bottom-center of a host view, holds
/// briefly, fades out. No persistent state; multiple calls just stack a fresh
/// label and let the older one finish its own animation.
@MainActor
enum Toast {
    /// Default 1 s on-screen hold (with ~0.18 s fade in/out).
    static func show(_ message: String, in host: NSView, hold: TimeInterval = 1.0) {
        let label = ToastLabel(text: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alphaValue = 0
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -28),
        ])

        let fade = 0.18
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = fade
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + hold + fade) { [weak label] in
            guard let label else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = fade
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                label.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak label] in
                label?.removeFromSuperview()
            }
        }
    }
}

@MainActor
private final class ToastLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let c = HarnessChrome.current
        layer?.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.92 : 0.95).cgColor

        label.stringValue = text
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = c.terminalBackground
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
