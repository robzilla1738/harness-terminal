import SwiftUI

/// Optional `harness-cli` install: the binary into Application Support, its directory onto the
/// PATH of the shells this account uses. The action itself lives in the wizard's footer
/// (`OnboardingWizardView.primaryAction`).
struct CommandLineStepView: View {
    let setup: OnboardingSetup

    private static let binDisplayPath = (HarnessCLIPaths.binDirectory.path as NSString).abbreviatingWithTildeInPath

    var body: some View {
        VStack(spacing: 28) {
            StepIntro(
                eyebrow: "Command line",
                title: "Drive Harness from any shell.",
                bodyText: "harness-cli opens tabs, runs commands, sends keys, and reads panes, for your scripts and agents. Optional: the app works without it."
            )

            RowList {
                IconRow(symbol: "terminal", title: "harness-cli", detail: Self.binDisplayPath) {
                    setup.cliInstalled
                        ? StatusPill(text: "Installed", tone: .success)
                        : StatusPill(text: "Not installed")
                }
                ForEach(setup.shells) { shell in
                    IconRow(symbol: "doc.text", title: shell.shell.rawValue,
                            detail: "Add PATH to \((shell.profileURL.path as NSString).abbreviatingWithTildeInPath); back up an existing file first") {
                        shell.alreadyHas
                            ? StatusPill(text: "Configured", tone: .success)
                            : StatusPill(text: "Not set up")
                    }
                }
            }

            if !setup.allowsSystemSetup {
                StatusNote(text: Text("Installation is disabled in this isolated preview so your shell profiles and regular Harness installation stay unchanged."))
            } else if let error = setup.cliError {
                StatusNote(text: Text(verbatim: "Couldn't finish: \(error)"), tone: .danger)
            } else if !setup.canInstallCLI {
                StatusNote(text: Text(verbatim: BinaryInstaller.InstallError.missingBundledTools.errorDescription ?? ""), tone: .danger)
            } else if setup.cliReady {
                StatusNote(text: Text("Ready. Open a new tab and try `harness-cli ls`."))
            }
        }
        .animation(Motion.spring, value: setup.cliReady)
        .animation(Motion.spring, value: setup.cliError)
    }
}
