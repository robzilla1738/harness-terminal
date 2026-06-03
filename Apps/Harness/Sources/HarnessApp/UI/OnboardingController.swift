import AppKit
import HarnessCore
import HarnessOnboarding

/// First-run onboarding entry point. Delegates to the immersive `HarnessOnboarding` wizard
/// (a borderless glass takeover embedded in the app) — shown once on first launch and
/// re-openable any time from **Help → Welcome to Harness**.
///
/// The wizard owns its own window lifetime and first-run flag; this enum is the thin,
/// stable surface the rest of the app (`AppDelegate`, `MainMenuBuilder`) calls.
@MainActor
enum OnboardingController {
    /// Present on first run only.
    static func presentIfNeeded() {
        configureEnvironment()
        HarnessOnboarding.presentIfNeeded()
    }

    /// Always present (Help menu).
    static func present() {
        configureEnvironment()
        HarnessOnboarding.present()
    }

    /// Bridge the isolated onboarding module to the core agent-hook installer, so the Setup
    /// step can detect installed agents and wire up notification hooks in one click.
    private static func configureEnvironment() {
        OnboardingEnvironment.detectAgents = {
            AgentHookInstaller.detectInstalledAgents().filter(AgentHookInstaller.canInstall).map { kind in
                OnboardingEnvironment.Agent(
                    id: kind.rawValue,
                    displayName: kind.displayName,
                    hooksInstalled: AgentHookInstaller.isInstalled(agent: kind)
                )
            }
        }
        OnboardingEnvironment.installHooks = { agentID in
            guard let kind = AgentKind(rawValue: agentID) else { return false }
            return (try? AgentHookInstaller.install(agent: kind)) != nil
        }
    }
}
