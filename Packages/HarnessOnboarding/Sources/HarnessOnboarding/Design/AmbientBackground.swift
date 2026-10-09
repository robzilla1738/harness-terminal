import SwiftUI
import AppKit

/// The full-screen field behind the wizard: Harness's black canvas with a few soft pools of light
/// drifting across it and a fine grain, so the takeover feels alive without competing with the panel.
/// Reduce Motion freezes the field.
struct AmbientBackground: View {
    var reduceMotion: Bool = false
    @State private var isActive = NSApp.isActive

    var body: some View {
        ZStack {
            if reduceMotion || !isActive {
                Canvas { ctx, size in Self.drawField(ctx, size, t: 0) }
            } else {
                // The drift is a few points a second, so 20 fps reads as smooth.
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                    Canvas { ctx, size in
                        Self.drawField(ctx, size, t: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }

            Canvas { ctx, size in Self.drawGrain(ctx, size) }
                .blendMode(.plusLighter)
        }
        .background(.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in isActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in isActive = false }
    }

    private static func drawField(_ ctx: GraphicsContext, _ size: CGSize, t: TimeInterval) {
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Rectangle().path(in: rect), with: .color(.black))

        let w = size.width, h = size.height
        let pools: [(phase: Double, center: CGPoint, amp: CGSize, radius: CGFloat, alpha: Double)] = [
            (0.0, CGPoint(x: w * 0.30, y: h * 0.18), CGSize(width: w * 0.12, height: h * 0.08), w * 0.42, 0.16),
            (1.9, CGPoint(x: w * 0.74, y: h * 0.40), CGSize(width: w * 0.10, height: h * 0.12), w * 0.36, 0.10),
            (3.6, CGPoint(x: w * 0.42, y: h * 0.88), CGSize(width: w * 0.16, height: h * 0.06), w * 0.46, 0.07),
        ]
        for pool in pools {
            let x = pool.center.x + cos(t * 0.07 + pool.phase) * pool.amp.width
            let y = pool.center.y + sin(t * 0.055 + pool.phase) * pool.amp.height
            let bounds = CGRect(x: x - pool.radius, y: y - pool.radius, width: pool.radius * 2, height: pool.radius * 2)
            ctx.fill(Ellipse().path(in: bounds), with: .radialGradient(
                Gradient(colors: [.white.opacity(pool.alpha), .white.opacity(pool.alpha * 0.25), .clear]),
                center: CGPoint(x: x, y: y), startRadius: 0, endRadius: pool.radius
            ))
        }

        // One slow diagonal sheen, like light across glass.
        let sheenX = w * 0.2 + cos(t * 0.04) * w * 0.12
        let band = CGRect(x: sheenX, y: -h * 0.2, width: w * 0.22, height: h * 1.4)
        var transform = CGAffineTransform(translationX: band.midX, y: band.midY)
            .rotated(by: -0.45)
            .translatedBy(x: -band.midX, y: -band.midY)
        ctx.fill(Path(CGPath(rect: band, transform: &transform)), with: .linearGradient(
            Gradient(colors: [.clear, .white.opacity(0.03), .clear]),
            startPoint: CGPoint(x: band.minX, y: band.midY),
            endPoint: CGPoint(x: band.maxX, y: band.midY)
        ))

        ctx.fill(Rectangle().path(in: rect), with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(0.7)]),
            center: CGPoint(x: w * 0.5, y: h * 0.48),
            startRadius: min(w, h) * 0.3,
            endRadius: max(w, h) * 0.75
        ))
    }

    private static func drawGrain(_ ctx: GraphicsContext, _ size: CGSize) {
        let spacing: CGFloat = 5
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> Double {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Double(seed % 1000) / 1000.0
        }

        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = 0
            while x < size.width {
                let r = rand()
                if r > 0.62 {
                    ctx.fill(Rectangle().path(in: CGRect(x: x, y: y, width: 1, height: 1)),
                             with: .color(.white.opacity(0.006 + r * 0.012)))
                }
                x += spacing
            }
            y += spacing
        }
    }
}
