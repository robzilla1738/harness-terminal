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
            fputs("install-hooks: missing agent name (e.g. claude-code, codex, cursor, grok, opencode, pi, hermes, openclaw)\n", stderr)
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
            if result.needsManualMerge {
                // We left the file untouched to avoid corrupting an existing config.
                print("\(kind.displayName): \(result.path.path) already defines a hooks section (or couldn't be edited safely).")
                print("Left it untouched — add the Harness hook by hand following 'docs/agent-hooks/\(kind.rawValue).md'.")
                exit(0)
            }
            if let backup = result.backedUp {
                print("(backed up existing config to \(backup.path))")
            }
            if result.replacedInvalidJSON {
                print("(existing config couldn't be read as text — replacing it; the backup above has the original)")
            }
            for legacy in result.removedLegacy {
                print("(removed legacy Harness hook file at \(legacy.path))")
            }
            print("Installed \(kind.displayName) hooks at \(result.path.path)")
            switch kind {
            case .hermes:
                print("Hermes requires consent: run 'hermes hooks' to approve the new hook before it fires.")
            case .openCode, .pi:
                print("Takes effect on the agent's next session (plugin/extension auto-loaded).")
            case .cursor:
                print("Note: Cursor's 'stop' hook is primarily an IDE/Agent-Chat hook; CLI support may vary.")
            default:
                break
            }
            print("See 'docs/agent-hooks/\(kind.rawValue).md' for details.")
        } catch {
            fputs("install-hooks: failed to write hooks for \(kind.displayName): \(error)\n", stderr)
            exit(1)
        }
    }
}
