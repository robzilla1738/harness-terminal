import SwiftUI
import AppKit

enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome, discover, notifications, commandLine, complete

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:       "Welcome"
        case .discover:      "Overview"
        case .notifications: "Notifications"
        case .commandLine:   "Command line"
        case .complete:      "Ready"
        }
    }
}

/// The wizard panel: progress and Skip on top, the step in the middle, and a footer with Back
/// and the step's one primary action (Return). A step with something to set up makes that the
/// primary action and offers "Not Now" beside it; once done, the primary becomes Continue.
struct OnboardingWizardView: View {
    let setup: OnboardingSetup
    let onFinish: () -> Void

    @State private var currentStep: OnboardingStep = .welcome
    @State private var movingForward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var steps: [OnboardingStep] { OnboardingStep.allCases }
    private var currentIndex: Int { currentStep.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 24)
                .padding(.horizontal, 28)

            stepArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.13), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 60, x: 0, y: 30)
        .onAppear(perform: setup.refresh)
        .onDisappear { setup.stopWaitingForNotifications() }
        // Pick up changes made elsewhere while the wizard was open: notifications turned on in
        // System Settings, an agent installed, a profile edited by hand.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !setup.isBusy { setup.refresh() }
        }
    }

    /// Near-black glass: the panel sits on the black ambient field like a piece of Harness's own
    /// chrome, a step lighter than the canvas around it.
    private var panelBackground: some View {
        ZStack {
            if reduceTransparency {
                Color(white: 0.07)
            } else {
                GlassEffectView(tint: NSColor(white: 0.1, alpha: 0.5), cornerRadius: 30)
                Color.black.opacity(0.35)
                LinearGradient(
                    colors: [.white.opacity(0.07), .white.opacity(0.025)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            progress
            Spacer(minLength: 0)
            if currentStep != .complete {
                Button("Skip Setup", action: onFinish)
                    .buttonStyle(GlassTextButtonStyle())
                    .disabled(setup.blocksNavigation)
            }
        }
        .frame(height: 30)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in
                Capsule()
                    .fill(.white.opacity(step == currentStep ? 0.9 : step.rawValue < currentIndex ? 0.38 : 0.14))
                    .frame(width: step == currentStep ? 18 : 6, height: 6)
            }
        }
        .animation(Motion.spring, value: currentStep)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(currentIndex + 1) of \(steps.count), \(currentStep.title)")
    }

    // MARK: - Steps

    private var stepArea: some View {
        GeometryReader { geometry in
            ScrollView {
                ZStack {
                    ForEach(steps) { step in
                        if step == currentStep {
                            stepContent(for: step)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                                .transition(transition)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .animation(Motion.spring, value: currentStep)
    }

    /// The outgoing step fades out quickly and the new one follows a beat later, sliding a little in
    /// the direction of travel, so two steps' text never overlaps at full strength. Reduce Motion
    /// keeps only the fades.
    private var transition: AnyTransition {
        let shift: CGFloat = reduceMotion ? 0 : (movingForward ? 24 : -24)
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: shift)).animation(Motion.spring.delay(0.1)),
            removal: .opacity.combined(with: .offset(x: -shift / 2)).animation(.easeIn(duration: 0.12))
        )
    }

    @ViewBuilder
    private func stepContent(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:       WelcomeStepView()
        case .discover:      DiscoverStepView()
        case .notifications: NotificationsStepView(setup: setup)
        case .commandLine:   CommandLineStepView(setup: setup)
        case .complete:      CompleteStepView()
        }
    }

    // MARK: - Footer

    private struct Action {
        let title: String
        let perform: () -> Void
        /// True when the action sets something up rather than moving on, so "Not Now" can skip it.
        var isSetup = false
    }

    private var primaryAction: Action {
        let next = Action(title: "Continue", perform: advance)
        switch currentStep {
        case .welcome:
            return Action(title: "Get Started", perform: advance)
        case .discover:
            return next
        case .notifications:
            guard setup.allowsSystemSetup else { return next }
            if setup.notifications == .undetermined {
                return Action(title: "Turn On Notifications", perform: setup.requestNotifications, isSetup: true)
            }
            if !setup.pendingHookAgents.isEmpty {
                return Action(title: setup.hooksError == nil ? "Install Hooks" : "Try Again",
                              perform: setup.installHooks, isSetup: true)
            }
            if setup.notifications == .denied {
                return Action(title: "Open System Settings", perform: NotificationPermission.openSystemSettings, isSetup: true)
            }
            return next
        case .commandLine:
            guard !setup.cliReady, setup.canInstallCLI else { return next }
            return Action(title: setup.cliError == nil ? "Install" : "Try Again", perform: setup.installCLI, isSetup: true)
        case .complete:
            return Action(title: "Start Using Harness", perform: onFinish)
        }
    }

    private var footer: some View {
        let action = primaryAction
        return HStack(spacing: 10) {
            if currentIndex > 0 {
                Button(action: goBack) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back")
                    }
                }
                .buttonStyle(GlassTextButtonStyle())
                .keyboardShortcut("[", modifiers: .command)
                .disabled(setup.blocksNavigation)
            }

            Spacer()

            if action.isSetup {
                Button("Not Now", action: advance)
                    .buttonStyle(GlassTextButtonStyle())
                    .disabled(setup.blocksNavigation)
            }

            // Not disabled while busy (every action ignores a press then), so the button stays
            // white behind its spinner instead of dimming.
            Button {
                guard !setup.isBusy else { return }
                action.perform()
            } label: {
                ZStack {
                    // Keep the button's width while the spinner shows.
                    Text(action.title).opacity(setup.isBusy ? 0 : 1)
                    if setup.isBusy {
                        Spinner()
                    }
                }
            }
            .buttonStyle(GlassPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .accessibilityLabel(setup.isBusy ? "Working" : action.title)
        }
    }

    private func advance() {
        guard !setup.blocksNavigation, currentIndex < steps.count - 1 else { return }
        setup.stopWaitingForNotifications()
        movingForward = true
        currentStep = steps[currentIndex + 1]
    }

    private func goBack() {
        guard !setup.blocksNavigation, currentIndex > 0 else { return }
        setup.stopWaitingForNotifications()
        movingForward = false
        currentStep = steps[currentIndex - 1]
    }
}
