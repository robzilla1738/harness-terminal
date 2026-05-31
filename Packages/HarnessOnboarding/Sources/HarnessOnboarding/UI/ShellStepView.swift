import SwiftUI
import Foundation

/// Shell integration step. Profile-editing behavior is unchanged; the UI presents it calmly.
struct ShellStepView: View {
    @State private var shells: [ShellInfo] = []
    @State private var messages: [String] = []
    @State private var isWorking = false
    @State private var success = false

    struct ShellInfo: Identifiable {
        let id = UUID()
        let name: String
        let profileURL: URL
        let line: String
        var alreadyHas: Bool
    }

    private var allConfigured: Bool { !shells.isEmpty && shells.allSatisfy(\.alreadyHas) }

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
        var result: [ShellInfo] = []
        let home = FileManager.default.homeDirectoryForCurrentUser

        let zsh = home.appendingPathComponent(".zshrc")
        result.append(ShellInfo(name: "zsh", profileURL: zsh,
                                line: "export PATH=\"\(HarnessCLIPaths.binDirectory.path):$PATH\"",
                                alreadyHas: containsLine(zsh)))

        let bash = home.appendingPathComponent(".bash_profile")
        result.append(ShellInfo(name: "bash", profileURL: bash,
                                line: "export PATH=\"\(HarnessCLIPaths.binDirectory.path):$PATH\"",
                                alreadyHas: containsLine(bash)))

        let fish = home.appendingPathComponent(".config/fish/config.fish")
        result.append(ShellInfo(name: "fish", profileURL: fish,
                                line: "set -gx PATH \(HarnessCLIPaths.binDirectory.path) $PATH",
                                alreadyHas: containsLine(fish)))

        shells = result
    }

    private func containsLine(_ url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return content.contains("Harness/bin")
    }

    private func updateShell(_ shell: ShellInfo) {
        isWorking = true
        defer { isWorking = false }

        let backup = shell.profileURL.appendingPathExtension("bak-\(Int(Date().timeIntervalSince1970))")
        do {
            if FileManager.default.fileExists(atPath: shell.profileURL.path) {
                try FileManager.default.copyItem(at: shell.profileURL, to: backup)
            } else {
                try FileManager.default.createDirectory(at: shell.profileURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try "".write(to: shell.profileURL, atomically: true, encoding: .utf8)
            }
            var content = (try? String(contentsOf: shell.profileURL, encoding: .utf8)) ?? ""
            if !content.hasSuffix("\n") && !content.isEmpty { content += "\n" }
            content += "\n# Added by Harness CLI Onboarding\n\(shell.line)\n"
            try content.write(to: shell.profileURL, atomically: true, encoding: .utf8)

            messages.append("Updated \(shell.name), backup \(backup.lastPathComponent)")
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
        isWorking = true
        defer { isWorking = false }
        let fishScript = """
        # Fish completion for harness-cli (embedded by the onboarding wizard)
        set -l __harness_cli_subcommands \\
            ping list-workspaces list-surfaces list-sessions list-windows list-panes list-agents has-session \\
            list-commands get-snapshot daemon-stats list-clients detach-client \\
            new-workspace new-session new-tab new-split \\
            select-workspace select-session select-tab \\
            close-tab close-session promote-session demote-session \\
            send send-keys capture-pane pipe-pane wait-for display-message respawn-pane \\
            kill-pane swap-pane resize-pane zoom-pane copy-mode select-pane \\
            rename-tab rename-session rename-workspace \\
            detect-agent install-hooks install-shell-integration attach attach-window notify \\
            bind-key unbind-key list-keys \\
            set-buffer list-buffers show-buffer delete-buffer paste-buffer save-buffer load-buffer \\
            select-layout next-layout previous-layout rotate-window \\
            break-pane join-pane move-pane renumber-windows link-window unlink-window \\
            set-option show-options set-environment show-environment \\
            bind-hook unbind-hook list-hooks control-mode install

        complete -c harness-cli -f -n "not __fish_seen_subcommand_from $__harness_cli_subcommands" \\
            -a "$__harness_cli_subcommands"
        """

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
