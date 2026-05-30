import Foundation
import HarnessCore

/// CLI presentation for `harness-cli install-hooks <agent>`. The actual file-writing /
/// merge / backup logic lives in `HarnessCore.AgentHookInstaller` (shared with the GUI's
/// "Install hooks" button). This shim only resolves the agent name, calls core, and prints
/// the same human-facing messages + exit codes the command always had.
enum AgentHookInstallerCLI {
    static func run(agentArg: String) {
        let trimmed = agentArg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fputs("install-hooks: missing agent name (e.g. claude-code, codex, cursor, pi, hermes, openclaw)\n", stderr)
            exit(1)
        }
        guard let kind = AgentHookInstaller.resolveAgentName(trimmed) else {
            fputs("install-hooks: unknown agent \"\(agentArg)\"\n", stderr)
            exit(1)
        }
        guard AgentHookInstaller.canInstall(kind) else {
            // Known agent, but it has no shell-command hook mechanism — Harness notifies
            // for it automatically via process detection. Informational, not an error.
            print("\(kind.displayName) is detected automatically — no hook file needed; Harness notifies when it stops or needs input.")
            exit(0)
        }
        do {
            let result = try AgentHookInstaller.install(agent: kind)
            if let backup = result.backedUp {
                print("(backed up existing config to \(backup.path))")
            }
            if result.replacedInvalidJSON {
                print("(existing config wasn't valid JSON — replacing it; the backup above has the original)")
            }
            print("Installed \(kind.displayName) hooks at \(result.path.path)")
            if kind == .claudeCode {
                print("Add 'docs/agent-hooks/claude-code.md' instructions for any custom workflows.")
            }
        } catch {
            fputs("install-hooks: failed to write hooks for \(kind.displayName): \(error)\n", stderr)
            exit(1)
        }
    }
}
