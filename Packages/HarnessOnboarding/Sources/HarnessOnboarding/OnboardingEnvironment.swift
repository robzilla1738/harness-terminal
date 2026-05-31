import Foundation

/// Injection seam that lets the (deliberately HarnessCore-free) onboarding module offer
/// agent-hook setup without importing the core installer. `HarnessApp` populates these
/// closures with the real `AgentHookInstaller`-backed implementations before presenting the
/// wizard; left unset, the Setup step's agent-hooks row simply hides, so the wizard stays
/// fully functional in isolation (and in previews/tests). Mirrors how the module already
/// wraps install paths behind its own helpers (`BinaryInstaller`, `NotificationPermission`).
@MainActor
public enum OnboardingEnvironment {
    public struct Agent: Identifiable, Equatable {
        /// Stable agent key (the host passes `AgentKind.rawValue`).
        public let id: String
        public let displayName: String
        public let hooksInstalled: Bool

        public init(id: String, displayName: String, hooksInstalled: Bool) {
            self.id = id
            self.displayName = displayName
            self.hooksInstalled = hooksInstalled
        }
    }

    /// The installable agents detected on this machine. Defaults to none (row stays hidden).
    public static var detectAgents: () -> [Agent] = { [] }

    /// Install Harness notification hooks for the agent `id`; returns true on success.
    public static var installHooks: (_ agentID: String) -> Bool = { _ in false }
}
