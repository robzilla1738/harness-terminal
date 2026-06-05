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
    /// An agent asked for approval or is otherwise waiting on the user (the explicit
    /// `harness-cli notify` path and tabs that transition to `.waiting`).
    case agentWaiting
    /// A detected agent stopped producing output (the working → idle/awaiting edge).
    case agentFinished
    /// A program rang the terminal bell (`\a`).
    case bell
    /// A foreground command that ran past `commandFinishedThresholdSeconds` finished in a
    /// pane the user wasn't watching.
    case commandFinished

    /// Settings-row label.
    public var title: String {
        switch self {
        case .agentWaiting: return "Agent needs input"
        case .agentFinished: return "Agent finished"
        case .bell: return "Terminal bell"
        case .commandFinished: return "Command finished"
        }
    }

    /// Settings-row hint shown under the label.
    public var detail: String {
        switch self {
        case .agentWaiting: return "When an agent asks for approval or is waiting on you."
        case .agentFinished: return "When a detected agent stops producing output."
        case .bell: return "When a program rings the terminal bell."
        case .commandFinished: return "When a long command finishes in a background pane."
        }
    }

    /// Default when the user hasn't made an explicit choice. Mirrors the pre-existing
    /// behavior: agent/bell events were on by default; command-finished was opt-in.
    public var defaultEnabled: Bool {
        switch self {
        case .agentWaiting, .agentFinished, .bell: return true
        case .commandFinished: return false
        }
    }
}
