import SwiftUI

/// Notification permission and agent hooks. Notifications are Harness's only signal outside its
/// own windows, so this step says plainly what they're for before macOS asks. The action itself
/// lives in the wizard's footer (`OnboardingWizardView.primaryAction`).
struct NotificationsStepView: View {
    let setup: OnboardingSetup

    private var notificationStatus: StatusPill {
        switch setup.notifications {
        case .granted:      StatusPill(text: "On", tone: .success)
        case .denied:       StatusPill(text: "Off", tone: .danger)
        case .undetermined: StatusPill(text: "Not set up")
        }
    }

    private var agentNames: String { setup.agents.map(\.displayName).formatted() }

    var body: some View {
        VStack(spacing: 28) {
            StepIntro(
                eyebrow: "Notifications",
                title: "Know the moment an agent needs you.",
                bodyText: "Notifications are how Harness reaches you outside its window: when an agent asks for approval, finishes, or fails, even while you're in another app."
            )

            RowList {
                IconRow(symbol: "bell.badge", title: "Notifications",
                        detail: "A banner and sound for each approval request, finished run, and failure.") {
                    notificationStatus
                }
                if !setup.agents.isEmpty {
                    IconRow(symbol: "point.3.connected.trianglepath.dotted", title: "Agent hooks",
                            detail: "\(agentNames) report the instant they stop, instead of Harness inferring it from their output.") {
                        setup.pendingHookAgents.isEmpty
                            ? StatusPill(text: "Installed", tone: .success)
                            : StatusPill(text: "Not installed")
                    }
                }
            }

            if let error = setup.hooksError {
                StatusNote(text: Text(verbatim: error), tone: .danger)
            } else if setup.notifications == .denied {
                StatusNote(text: Text("macOS asks only once. Turn Harness on in System Settings ▸ Notifications."))
            } else if setup.notificationsReady {
                StatusNote(text: Text("All set. ⇧⌘U also jumps to whichever agent is waiting."))
            }
        }
        .animation(Motion.spring, value: setup.notifications)
        .animation(Motion.spring, value: setup.agents)
        .animation(Motion.spring, value: setup.hooksError)
    }
}
