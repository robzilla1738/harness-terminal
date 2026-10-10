import Foundation

/// The distinct events Harness can raise a desktop notification for. This is the single
/// source of truth for the user-facing "which events notify me" list: the Settings UI
/// builds one toggle per case, and `SessionCoordinator` gates each banner on the matching
/// case via `HarnessSettings.isEventEnabled(_:)`. Add a case here and a new, fully wired
/// toggle appears — no scattered edits.
///
/// `rawValue` is the persisted key in `HarnessSettings.notificationEvents`, so the spellings
/// below are part of the on-disk format — don't rename them without a migration.
public enum NotificationEvent: String, CaseIterable, Codable, Sendable {
    /// An agent or program is blocked on the user: an OSC 7501 `blocked` report, the explicit
    /// `harness-cli notify` path, or a program's own desktop-notification request.
    case systemSleep, systemWake
    case agentWaiting
    /// Work finished: an OSC 7501 `done` report, or a detected agent going quiet (the
    /// working → idle/awaiting edge).
    case agentFinished
    /// A program reported an error (OSC 7501 `error`).
    case failed
    /// A program rang the terminal bell (`\a`).
    case bell
    /// A foreground command that ran past `commandFinishedThresholdSeconds` finished in a
    /// pane the user wasn't watching.
    case commandFinished

    /// Settings-row label.
    public var title: String {
        switch self {
        case .systemSleep: return "System sleep"
        case .systemWake: return "System wake"
        case .agentWaiting: return "Needs you"
        case .agentFinished: return "Finished"
        case .failed: return "Failed"
        case .bell: return "Bell"
        case .commandFinished: return "Long command finished"
        }
    }

    /// Settings-row hint shown under the label.
    public var detail: String {
        switch self {
        case .systemSleep: return "Best-effort notification before macOS sleeps; local execution pauses."
        case .systemWake: return "macOS woke; elapsed sleep is reported when observed."
        case .agentWaiting: return "An agent or program is waiting for your input or approval."
        case .agentFinished: return "An agent stops working, or a program reports it's done."
        case .failed: return "A program reports an error."
        case .bell: return "A program rings the terminal bell."
        case .commandFinished: return "A command that ran longer than the threshold finishes."
        }
    }

    /// Default when the user hasn't made an explicit choice. Agent, failure, and bell events
    /// are on; command-finished is opt-in.
    public var defaultEnabled: Bool {
        switch self {
        case .agentWaiting, .agentFinished, .failed, .bell: return true
        case .commandFinished, .systemSleep, .systemWake: return false
        }
    }
}
