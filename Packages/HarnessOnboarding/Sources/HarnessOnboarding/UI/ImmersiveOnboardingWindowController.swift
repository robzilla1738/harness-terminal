import AppKit
import SwiftUI

/// The full-screen, borderless immersive shell for the Harness CLI onboarding.
@MainActor
final class ImmersiveOnboardingWindowController: NSWindowController, NSWindowDelegate {

    /// Called once the wizard fades out and closes. Embedded in Harness.app this just clears
    /// the owning reference and reveals the app — it must never terminate the host process.
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let panel = ImmersivePanel(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .modalPanel
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .stationary]
        panel.isMovableByWindowBackground = false
        panel.alphaValue = 0.0
        // Lock to a fixed dark appearance. The onboarding is designed dark (near-black ambient
        // field, light text/logo), but the glass backdrop (NSGlassEffectView / NSVisualEffectView)
        // follows the window's appearance — unpinned on a light-mode Mac it renders light and the
        // light text becomes unreadable. Pinning darkAqua makes the backdrop dark to match the
        // content, with no light/dark switching.
        panel.appearance = NSAppearance(named: .darkAqua)

        super.init(window: panel)
        panel.delegate = self

        let root = ImmersiveRootView(
            onFinish: { [weak self] in self?.closeWithFade(launchDemo: false) },
            onFinishWithDemo: { [weak self] in self?.closeWithFade(launchDemo: true) },
            onSkip: { [weak self] in self?.closeWithFade(launchDemo: false) }
        )
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        guard let content = panel.contentView else { return }
        content.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: content.topAnchor),
            hosting.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hosting.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        panel.onCancel = { [weak self] in self?.closeWithFade(launchDemo: false) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.frame, display: true) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        WindowBlur.apply(radius: 72, to: window)

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = reduce ? 0.12 : 0.55
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            window.animator().alphaValue = 1.0
        }
    }

    private var isClosing = false

    private func closeWithFade(launchDemo: Bool) {
        guard !isClosing else { return }
        isClosing = true

        if launchDemo { NSApp.activate(ignoringOtherApps: true) }

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = reduce ? 0.1 : 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window?.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.close()
                self?.onDismiss()
                if launchDemo {
                    NSApp.windows.first(where: { !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
                }
            }
        })
    }
}

private final class ImmersivePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct ImmersiveRootView: View {
    let onFinish: () -> Void
    let onFinishWithDemo: () -> Void
    let onSkip: () -> Void

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            AmbientBackground(reduceMotion: reduceMotion)

            Rectangle()
                .fill(reduceTransparency ? .black.opacity(0.78) : .black.opacity(0.06))
                .ignoresSafeArea()

            if !reduceTransparency {
                GlassEffectView(tint: .black, cornerRadius: 0)
                    .opacity(0.48)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            OnboardingWizardView(onFinish: onFinish,
                                 onFinishWithDemo: onFinishWithDemo,
                                 onSkip: onSkip)
                .frame(maxWidth: 980)
                .padding(40)
                .scaleEffect(appeared ? 1.0 : (reduceMotion ? 1.0 : 0.97))
                .opacity(appeared ? 1.0 : 0.0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15)
                          : .spring(response: 0.6, dampingFraction: 0.82).delay(0.05)) {
                appeared = true
            }
        }
    }
}
