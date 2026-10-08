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
                            detail: "PATH entry in \((shell.profileURL.path as NSString).abbreviatingWithTildeInPath), backed up first") {
                        shell.alreadyHas
                            ? StatusPill(text: "On PATH", tone: .success)
                            : StatusPill(text: "Not set up")
                    }
                }
            }

            if let error = setup.cliError {
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
