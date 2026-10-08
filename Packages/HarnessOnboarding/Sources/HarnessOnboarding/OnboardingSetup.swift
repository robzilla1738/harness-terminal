import AppKit
import Observation

/// What the Notifications and Command Line steps show and do, in one place. The wizard's footer
/// reads it to offer each step's single primary action, and navigation (Back, Skip, Esc) is locked
/// while `isBusy` so the wizard can't be torn down halfway through a write.
///
/// Every check re-runs on `refresh()`, so reopening the wizard from Help ▸ Welcome to Harness shows
/// what is already set up instead of offering to do it again.
@MainActor @Observable
final class OnboardingSetup {
    var cliInstalled = false
    /// The bundled `harness-cli` (or a dev build) to install from; nil when this copy has none.
    var cliSource: URL?
    /// The login shell plus any shell that already has a profile — never all three by default.
    var shells: [ShellProfileInstaller.Profile] = []
    var isInstallingCLI = false
    var cliError: String?

    var notifications: NotificationPermission.State = .undetermined
    var agents: [OnboardingEnvironment.Agent] = []
    var isInstallingHooks = false
    var hooksError: String?

    var isBusy: Bool { isInstallingCLI || isInstallingHooks }

    var cliReady: Bool { cliInstalled && shells.allSatisfy(\.alreadyHas) }
    var canInstallCLI: Bool { cliSource != nil || cliInstalled }

    var pendingHookAgents: [OnboardingEnvironment.Agent] { agents.filter { !$0.hooksInstalled } }
    var notificationsReady: Bool { notifications == .granted && pendingHookAgents.isEmpty }

    func refresh() {
        cliInstalled = FileManager.default.isExecutableFile(atPath: HarnessCLIPaths.installedCLIPath.path)
        cliSource = BinaryInstaller.bundledSource(named: "harness-cli")
        shells = ShellProfileInstaller.relevantProfiles()
        agents = OnboardingEnvironment.detectAgents()
        NotificationPermission.current { [weak self] in self?.notifications = $0 }
    }

    // MARK: - Notifications

    /// Ask for notification permission when macOS hasn't asked yet, then wire up hooks for every
    /// detected agent that lacks them. Hooks call the installed `harness-cli`, so its binary is
    /// copied first when it isn't there yet (shell profiles are left to the Command Line step).
    func setUpNotifications() {
        guard !isBusy else { return }
        if notifications == .undetermined {
            NotificationPermission.request { [weak self] state in
                self?.notifications = state
                self?.installHooks()
            }
        } else {
            installHooks()
        }
    }

    private func installHooks() {
        let pending = pendingHookAgents
        guard !pending.isEmpty, !isInstallingHooks else { return }
        isInstallingHooks = true
        hooksError = nil
        Task {
            if !cliInstalled {
                do {
                    try await Self.installBinaries()
                } catch {
                    finishHooks(error: "Couldn't install harness-cli, which agent hooks call: \(error.localizedDescription)")
                    return
                }
                cliInstalled = FileManager.default.isExecutableFile(atPath: HarnessCLIPaths.installedCLIPath.path)
            }
            let failed = pending.filter { !OnboardingEnvironment.installHooks($0.id) }
            finishHooks(error: failed.isEmpty
                ? nil
                : "Couldn't install hooks for \(failed.map(\.displayName).formatted()). Run harness-cli install-hooks \(failed[0].id) in a terminal to see why.")
        }
    }

    private func finishHooks(error: String?) {
        agents = OnboardingEnvironment.detectAgents()
        hooksError = error
        isInstallingHooks = false
    }

    // MARK: - Command line

    /// Copy `harness-cli` into Application Support, add its directory to each relevant shell
    /// profile (with a backup), and write fish completions when fish is one of them.
    func installCLI() {
        guard !isBusy, canInstallCLI else { return }
        isInstallingCLI = true
        cliError = nil
        Task {
            do {
                if !cliInstalled { try await Self.installBinaries() }
                for shell in shells where !shell.alreadyHas {
                    try ShellProfileInstaller.install(shell.shell)
                }
                if shells.contains(where: { $0.shell == .fish }) { try installFishCompletion() }
                NSSound(named: "Glass")?.play()
            } catch {
                cliError = error.localizedDescription
            }
            isInstallingCLI = false
            refresh()
        }
    }

    /// The binary copy and its version probes block on child processes, so they run off the main actor.
    private static func installBinaries() async throws {
        let probe = BinaryInstaller.buildNumberProbe
        try await Task.detached { try BinaryInstaller.performInstall(probe: probe) }.value
    }

    /// The script comes from the host's catalog-driven generator (the one `harness-cli completions
    /// fish` prints), injected through `OnboardingEnvironment`; without a host there is nothing to write.
    private func installFishCompletion() throws {
        guard let script = OnboardingEnvironment.fishCompletionScript() else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/fish/completions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try script.write(to: dir.appendingPathComponent("harness-cli.fish"), atomically: true, encoding: .utf8)
    }
}
