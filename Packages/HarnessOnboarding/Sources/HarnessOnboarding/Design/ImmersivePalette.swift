import SwiftUI

/// Design tokens for the onboarding wizard. Self-contained (no dependency on the app), but matched
/// to Harness's default look: a pure-black canvas, white at stepped alphas for everything else,
/// and colour only for status. The wizard is always dark, whatever the system appearance.
enum ImmersivePalette {
    // Plain `Color` literals (not derived from main-actor NSColor statics) so any isolation
    // context can use them.
    enum SUI {
        static let textPrimary = Color.white.opacity(0.94)
        static let textSecondary = Color.white.opacity(0.62)
        static let textTertiary = Color.white.opacity(0.40)
        static let border = Color.white.opacity(0.08)
        static let success = Color(.sRGB, red: 0.59, green: 0.83, blue: 0.55, opacity: 1)
        static let danger  = Color(.sRGB, red: 0.93, green: 0.49, blue: 0.55, opacity: 1)
    }

    enum Motion {
        static let fast: TimeInterval = 0.16
        /// The "glass entrance" spring used for the panel, step changes, and status changes.
        static let springResponse: Double = 0.48
        static let springDamping: Double = 0.86
    }
}
