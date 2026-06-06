import SwiftUI
import AppKit

enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome, discover, setup, shell, complete

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:  "Intro"
        case .discover: "Overview"
        case .setup:    "Install"
        case .shell:    "Shell"
        case .complete: "Ready"
        }
    }
}

struct OnboardingWizardView: View {
    let onFinish: () -> Void
    let onFinishWithDemo: () -> Void
    let onSkip: () -> Void

    @State private var currentStep: OnboardingStep = .welcome
    /// True while the current step is running a one-shot install/apply (Setup or Shell). The footer
    /// Continue and the header Skip are locked while it's set so the user can't advance — or tear
    /// down the wizard — mid-write. The work itself is synchronous main-actor I/O (intentionally not
    /// cancellable), so this is purely a UI gate against a confusing half-applied state.
    @State private var stepBusy = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var steps: [OnboardingStep] { OnboardingStep.allCases }
    private var currentIndex: Int { currentStep.rawValue }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 26)
                .padding(.horizontal, 32)

            stepArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 32)
                .padding(.bottom, 28)
        }
        .frame(minWidth: 700, maxWidth: 860, minHeight: 560, maxHeight: 640)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.26), radius: 46, x: 0, y: 24)
        .shadow(color: .white.opacity(0.13), radius: 80, x: 0, y: -24)
    }

    private var panelBackground: some View {
        ZStack {
            if reduceTransparency {
                Color.black.opacity(0.76)
            } else {
                GlassEffectView(tint: NSColor(white: 0.62, alpha: 0.18), cornerRadius: 34)
                LinearGradient(
                    colors: [.white.opacity(0.18), .white.opacity(0.085), .white.opacity(0.035)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            if currentStep == .welcome {
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 9) {
                    ForEach(steps) { step in
                        stepperDot(step)
                    }
                }
            }

            Spacer(minLength: 0)

            if currentStep != .complete {
                Button("Skip", action: onSkip)
                    .buttonStyle(GlassSmallButtonStyle())
                    .accessibilityLabel("Skip onboarding")
                    .disabled(stepBusy)
            }
        }
        .frame(height: 24)
    }

    private func stepperDot(_ step: OnboardingStep) -> some View {
        let isCurrent = step == currentStep
        let isDone = step.rawValue < currentIndex

        return Circle()
            .fill(Color.white.opacity(isCurrent ? 0.9 : isDone ? 0.38 : 0.16))
            .frame(width: isCurrent ? 7 : 5, height: isCurrent ? 7 : 5)
            .animation(Motion.spring, value: currentStep)
            .accessibilityLabel("\(step.title)\(isCurrent ? ", current step" : isDone ? ", completed" : "")")
    }

    private var stepArea: some View {
        ZStack {
            ForEach(steps) { step in
                if step == currentStep {
                    stepContent(for: step)
                        .padding(.horizontal, 56)
                        .transition(
                            reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.985)).combined(with: .offset(y: 10)),
                                removal: .opacity.combined(with: .scale(scale: 1.01)).combined(with: .offset(y: -6))
                            )
                        )
                }
            }
        }
        .animation(Motion.spring, value: currentStep)
    }

    @ViewBuilder
    private func stepContent(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome:  WelcomeStepView()
        case .discover: DiscoverStepView()
        case .setup:    SetupStepView(busy: $stepBusy)
        case .shell:    ShellStepView(busy: $stepBusy)
        case .complete: CompleteStepView(onOpenDemo: onFinishWithDemo)
        }
    }

    private var footer: some View {
        HStack {
            if currentIndex > 0 {
                Button("Back", action: goBack)
                    .buttonStyle(GlassSecondaryButtonStyle())
            }

            Spacer()

            if currentStep == .complete {
                Button("Done", action: onFinish)
                    .buttonStyle(GlassPrimaryButtonStyle(minWidth: 118))
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(currentStep == .welcome ? "Start" : "Continue", action: advance)
                    .buttonStyle(GlassPrimaryButtonStyle(minWidth: 118))
                    .keyboardShortcut(.defaultAction)
                    .disabled(stepBusy)
            }
        }
    }

    private func advance() {
        // Locked while the current step is mid-install/apply (see `stepBusy`).
        guard !stepBusy, currentIndex < steps.count - 1 else { return }
        stepBusy = false   // the step we're leaving can't be busy anymore
        currentStep = steps[currentIndex + 1]
    }

    private func goBack() {
        guard !stepBusy, currentIndex > 0 else { return }
        stepBusy = false
        currentStep = steps[currentIndex - 1]
    }
}
