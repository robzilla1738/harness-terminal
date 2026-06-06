import SwiftUI
import Foundation

/// Shell integration step. Profile-editing behavior is unchanged; the UI presents it calmly.
struct ShellStepView: View {
    /// Surfaced to the wizard so it can lock Continue/Skip while a profile update / completion write runs.
    @Binding var busy: Bool
    @State private var shells: [ShellInfo] = []
    @State private var messages: [String] = []
    @State private var isWorking = false
    @State private var success = false

    struct ShellInfo: Identifiable {
        let id: ShellProfileInstaller.Shell
        let shell: ShellProfileInstaller.Shell
        let name: String
        let profileURL: URL
        var alreadyHas: Bool
    }

    private var allConfigured: Bool { !shells.isEmpty && shells.allSatisfy(\.alreadyHas) }
    /// No shell has the Harness PATH block yet — leaving now means `harness-cli` isn't on PATH.
    private var noneConfigured: Bool { !shells.isEmpty && shells.allSatisfy { !$0.alreadyHas } }

    var body: some View {
        VStack(spacing: 24) {
            StepIntro(
                eyebrow: "Shell",
                title: allConfigured || success ? "Your PATH is ready." : "Add Harness to your shell.",
                bodyText: "Harness updates zsh, bash, and fish with timestamped backups. Open a new terminal after this."
            )

            VStack(spacing: 0) {
                ForEach(Array(shells.enumerated()), id: \.element.id) { index, shell in
                    shellRow(shell)
                        .padding(.vertical, 12)
                    if index < shells.count - 1 {
                        Rectangle().fill(.white.opacity(0.075)).frame(height: 1)
                    }
                }
            }
            .frame(maxWidth: 500)

            if !messages.isEmpty {
                Text(messages.suffix(2).joined(separator: "  /  "))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            // Non-blocking heads-up if the user leaves this step with no profile updated: harness-cli
            // won't be on PATH until shell integration is applied, and the wizard reopens any time.
            if noneConfigured && !success {
                Text("Skip and harness-cli won't be on your PATH until you apply shell integration. Reopen this anytime from Help → Welcome to Harness.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 460)
                    .transition(.opacity)
            }

            Button(action: applyIntegration) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text(success || allConfigured ? "Refresh completion" : "Apply")
                }
            }
            .buttonStyle(GlassPrimaryButtonStyle(minWidth: 140))
            .disabled(isWorking)
        }
        .animation(Motion.spring, value: noneConfigured)
        .onChange(of: isWorking) { busy = isWorking }
        .onAppear(perform: detectShells)
    }

    private func shellRow(_ shell: ShellInfo) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(shell.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                Text(shell.profileURL.lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if shell.alreadyHas {
                StatusPill(text: "configured", tone: .success)
            } else {
                Button("Update") { updateShell(shell) }
                    .buttonStyle(GlassSmallButtonStyle())
                    .disabled(isWorking)
            }
        }
    }

    private func detectShells() {
        shells = ShellProfileInstaller.profiles().map {
            ShellInfo(
                id: $0.shell,
                shell: $0.shell,
                name: $0.shell.rawValue,
                profileURL: $0.profileURL,
                alreadyHas: $0.alreadyHas
            )
        }
    }

    private func updateShell(_ shell: ShellInfo) {
        isWorking = true
        defer { isWorking = false }

        do {
            let result = try ShellProfileInstaller.install(shell.shell)
            let backup = result.backupURL.map { ", backup \($0.lastPathComponent)" } ?? ""
            messages.append(result.alreadyConfigured ? "\(shell.name) already configured" : "Updated \(shell.name)\(backup)")
            detectShells()
        } catch {
            messages.append("Failed to update \(shell.name): \(error.localizedDescription)")
        }
    }

    private func applyIntegration() {
        for shell in shells where !shell.alreadyHas {
            updateShell(shell)
        }
        installFishCompletion()
    }

    private func installFishCompletion() {
        // Single source of truth: the fish script comes from the host's catalog-driven generator
        // (`CompletionGenerator.script(for: .fish)`, injected via OnboardingEnvironment) — the same
        // one `harness-cli completions fish` and the installer emit. When the host hasn't wired it
        // (preview/test isolation) we skip rather than embed a second, drift-prone command list.
        guard let fishScript = OnboardingEnvironment.fishCompletionScript() else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/fish/completions", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("harness-cli.fish")
            try fishScript.write(to: url, atomically: true, encoding: .utf8)
            messages.append("Fish completion installed")
            success = true
        } catch {
            messages.append("Fish completion failed: \(error.localizedDescription)")
        }
    }
}
