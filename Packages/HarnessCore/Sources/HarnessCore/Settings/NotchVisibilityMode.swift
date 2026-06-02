import Foundation

/// Visibility policy for the macOS top-center Agent Notch HUD.
public enum NotchVisibilityMode: String, Codable, Sendable, CaseIterable {
    /// Follow the current experience mode. The notch is enabled only for Agent Workspace.
    case automatic
    /// Always show the notch HUD.
    case on
    /// Never show the notch HUD.
    case off

    public func isEnabled(for experienceMode: ExperienceMode) -> Bool {
        switch self {
        case .automatic:
            return experienceMode == .agent
        case .on:
            return true
        case .off:
            return false
        }
    }
}
