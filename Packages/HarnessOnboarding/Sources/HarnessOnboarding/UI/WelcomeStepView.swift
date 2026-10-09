import SwiftUI
import AppKit

/// First screen: the Harness mark, name, and what it is in one sentence.
struct WelcomeStepView: View {
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            logo
                .frame(width: 120, height: 120)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.92)
                .accessibilityHidden(true)
                .padding(.bottom, 34)

            Text("Welcome to Harness")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-0.8)
                .foregroundStyle(ImmersivePalette.SUI.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 14)

            Text("Your shell, with persistent sessions, connected workspaces, and optional agent notifications.")
                .font(.system(size: 16))
                .foregroundStyle(ImmersivePalette.SUI.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440)

            Spacer(minLength: 0)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 12)
        .onAppear(perform: animateIn)
    }

    @ViewBuilder
    private var logo: some View {
        if let image = Self.logoImage() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: "app.connected.to.app.below.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(ImmersivePalette.SUI.textPrimary)
        }
    }

    /// The transparent brand mark the app bundles (see `package-app.sh`), else the app icon.
    static func logoImage(bundle: Bundle = .main) -> NSImage? {
        if let url = bundle.url(forResource: "HarnessLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    private func animateIn() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.8, dampingFraction: 0.86).delay(0.1)) {
            appeared = true
        }
    }
}
