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
                title: "Stay informed without watching every pane.",
                bodyText: "Optional alerts for supported approval, completion, and failure events. Choose which events, banners, and sounds you want in Settings."
            )

            RowList {
                IconRow(symbol: "bell.badge", title: "Notifications",
                        detail: "Allow macOS notifications. Delivery also follows your Harness settings and Focus preferences.") {
                    notificationStatus
                }
                if !setup.agents.isEmpty {
                    IconRow(symbol: "point.3.connected.trianglepath.dotted", title: "Agent hooks",
                            detail: "Add hooks to \(agentNames) settings, with backups. Supported events vary by agent; harness-cli is installed if needed.") {
                        setup.pendingHookAgents.isEmpty
                            ? StatusPill(text: "Installed", tone: .success)
                            : StatusPill(text: "Not installed")
                    }
                }
            }

            if !setup.allowsSystemSetup {
                StatusNote(text: Text("This isolated preview leaves system permissions and agent settings unchanged. Setup is available in your regular Harness app."))
            } else if let error = setup.hooksError {
                StatusNote(text: Text(verbatim: error), tone: .danger)
            } else if setup.notifications == .denied {
                StatusNote(text: Text("macOS asks only once. Turn Harness on in System Settings ▸ Notifications."))
            } else if setup.notificationsReady {
                StatusNote(text: Text("Permission is enabled. Harness notification preferences still apply; ⇧⌘U jumps to a waiting agent."))
            }
        }
        .animation(Motion.spring, value: setup.notifications)
        .animation(Motion.spring, value: setup.agents)
        .animation(Motion.spring, value: setup.hooksError)
    }
}
