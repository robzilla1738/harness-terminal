import Foundation
import HarnessCore

/// Executes hook-bound `Command`s server-side. Hooks fire fire-and-forget on the
/// registry's hook queue (never while the registry lock is held), so this maps each
/// command onto the registry's existing IPC handlers — making a hook-fired verb
/// behave exactly like the same verb issued over the CLI.
///
/// The IPC-mappable verbs flow through the shared `CommandIPCTranslator` (the same
/// one the attach-window compositor uses), resolving the active target from the
/// registry's snapshot, so there is a single command→IPC mapping. The two daemon-
/// native verbs the IPC layer doesn't model (`run-shell` / `if-shell`),
/// `display-message`, and `sequence` are handled directly. Verbs that have no
/// server-side meaning as a hook reaction (UI overlays, mode toggles, keybinding
/// edits) log rather than silently no-op, so the gap stays visible.
/// `@unchecked Sendable`: holds only a weak reference to the (already `@unchecked
/// Sendable`) registry and is invoked serially on the registry's hook queue.
final class DaemonCommandExecutor: @unchecked Sendable {
    private weak var registry: SurfaceRegistry?

    init(registry: SurfaceRegistry) {
        self.registry = registry
    }

    func execute(_ command: Command, context: FormatContext) {
        guard let registry else { return }
        switch command {
        case let .sequence(commands):
            for sub in commands { execute(sub, context: context) }

        case let .displayMessage(format):
            _ = registry.handle(.displayMessage(format: format))

        case let .runShell(shellCommand, captureToBuffer):
            registry.runShellForHook(shellCommand, captureToBuffer: captureToBuffer)

        case let .ifShell(condition, then, otherwise):
            if registry.evaluateShellCondition(condition) {
                execute(then, context: context)
            } else if let otherwise {
                execute(otherwise, context: context)
            }

        default:
            // Everything else: resolve against the global active chain and run
            // through the shared translator — identical to the CLI/compositor.
            let target = CommandTarget(snapshot: registry.snapshot)
            let baseIndex = registry.optionStore.get("base-index")?.intValue ?? 0
            let paneBaseIndex = registry.optionStore.get("pane-base-index")?.intValue ?? 0
            switch CommandIPCTranslator.translate(command, target: target, baseIndex: baseIndex, paneBaseIndex: paneBaseIndex) {
            case let .requests(requests):
                for request in requests { _ = registry.handle(request) }
            case .clientLocal:
                fputs("HarnessDaemon: hook command has no server-side action: \(command.shortDescription)\n", stderr)
            case .unresolved:
                fputs("HarnessDaemon: hook command had no resolvable target: \(command.shortDescription)\n", stderr)
            }
        }
    }
}
