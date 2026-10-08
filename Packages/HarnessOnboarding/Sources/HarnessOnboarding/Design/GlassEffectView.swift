import SwiftUI
import AppKit

/// A reusable glass/vibrancy backdrop that matches the "Liquid Glass" + terminal aesthetic
/// used throughout Harness (and the original macOS immersive onboarding guide).
///
/// - On macOS 26+: uses the real `NSGlassEffectView` with a subtle tint.
/// - Pre-26: `NSVisualEffectView` (.underWindowBackground + behindWindow) + a near-opaque
///   theme-tinted overlay so the glass doesn't feel too light on older systems.
/// - The tint should be the resting chrome color (black, like Harness's default canvas) so the
///   panel reads as a floating piece of the same surface.
struct GlassEffectView: NSViewRepresentable {
    var tint: NSColor = .black
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true

        let backdrop: NSView
        if let glass = RuntimeGlassEffectView.make(cornerRadius: cornerRadius, tintColor: tint) {
            backdrop = glass
        } else {
            let vibrancy = NSVisualEffectView()
            vibrancy.material = .underWindowBackground
            vibrancy.blendingMode = .behindWindow
            vibrancy.state = .active
            backdrop = vibrancy
        }
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)

        // On pre-26 we lay a strong tint overlay so the vibrancy reads as the same
        // dark glass as the 26+ path (and matches the main Harness onboarding panel).
        let overlay = NSView()
        overlay.wantsLayer = true
        if RuntimeGlassEffectView.isGlass(backdrop) {
            overlay.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            overlay.layer?.backgroundColor = tint.withAlphaComponent(0.24).cgColor
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The tint/overlay is static for a given window; if we ever need live theme
        // switching we can expose more state here.
    }
}

@MainActor
private enum RuntimeGlassEffectView {
    static func make(cornerRadius: CGFloat, tintColor: NSColor) -> NSView? {
        guard #available(macOS 26.0, *),
              let glassType = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
              let glass = glassType.init() as? NSView else {
            return nil
        }
        glass.setValue(NSNumber(value: Double(cornerRadius)), forKey: "cornerRadius")
        glass.setValue(tintColor, forKey: "tintColor")
        return glass
    }

    static func isGlass(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).hasSuffix("NSGlassEffectView")
    }
}
