import AppKit
import Observation

/// What the Notifications and Command Line steps show and do, in one place. The wizard's footer
/// reads it to offer each step's single primary action. Only local installs lock navigation;
/// waiting for the optional macOS permission prompt must never trap the user here.
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
    var isRequestingNotifications = false
    @ObservationIgnored var notificationRequest: @MainActor (@escaping @MainActor @Sendable (Result<NotificationPermission.State, Error>) -> Void) -> Void = NotificationPermission.request
    @ObservationIgnored var notificationTimeout: Duration = .seconds(15)
    @ObservationIgnored private var notificationWait: Task<Void, Never>?
    private var notificationRequestID: UUID?
    var hooksError: String?

    var isBusy: Bool { isInstallingCLI || isInstallingHooks || isRequestingNotifications }
    var blocksNavigation: Bool { isInstallingCLI || isInstallingHooks }
    var allowsSystemSetup: Bool { !HarnessCLIPaths.hasHomeOverride }

    var cliReady: Bool { cliInstalled && cliError == nil && shells.allSatisfy(\.alreadyHas) }
    var canInstallCLI: Bool { allowsSystemSetup && (cliSource != nil || cliInstalled) }

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

    /// Permission and agent configuration are separate, explicit choices.
    func requestNotifications() {
        guard !isBusy, allowsSystemSetup else { return }
        isRequestingNotifications = true
        hooksError = nil
        let requestID = UUID()
        notificationRequestID = requestID
        notificationWait = Task { [weak self, notificationTimeout] in
            do { try await Task.sleep(for: notificationTimeout) }
            catch { return }
            guard let self, self.notificationRequestID == requestID else { return }
            self.stopWaitingForNotifications()
            self.hooksError = "macOS hasn't answered the notification request. You can try again or continue with Not Now and enable notifications in System Settings later."
        }
        notificationRequest { [weak self] result in
            guard let self, self.notificationRequestID == requestID else { return }
            self.stopWaitingForNotifications()
            switch result {
            case let .success(state): self.notifications = state
            case let .failure(error): self.hooksError = error.localizedDescription
            }
        }
    }

    func stopWaitingForNotifications() {
        notificationWait?.cancel()
        notificationWait = nil
        notificationRequestID = nil
        isRequestingNotifications = false
    }

    func installHooks() {
        guard !isBusy, allowsSystemSetup else { return }
        let pending = pendingHookAgents
        guard !pending.isEmpty else { return }
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
            let failures = pending.compactMap { agent -> String? in
                do { try OnboardingEnvironment.installHooks(agent.id); return nil }
                catch { return "\(agent.displayName): \(error.localizedDescription)" }
            }
            finishHooks(error: failures.isEmpty ? nil : failures.joined(separator: "\n"))
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
        guard let profile = shells.first(where: { $0.shell == .fish }) else { return }
        let dir = profile.profileURL.deletingLastPathComponent().appendingPathComponent("completions", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try script.write(to: dir.appendingPathComponent("harness-cli.fish"), atomically: true, encoding: .utf8)
    }
}
