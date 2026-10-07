import Foundation

/// Runs a tmux-style command string (`split-window -h`) against a daemon from outside the
/// app: parse, translate against a fresh snapshot, send. The same `CommandParser` →
/// `CommandIPCTranslator` path the daemon's hook executor and the compositor use.
public enum CommandRunner {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case parse(String)
        /// A UI-only verb (overlays, copy mode, prompts) that only the app can perform.
        case appOnly(String)
        case unresolved(String)
        case daemon(String)

        public var description: String {
            switch self {
            case let .parse(message): return message
            case let .appOnly(verb): return "\(verb) only runs inside the Harness app"
            case let .unresolved(verb): return "\(verb): no pane, tab, or session to act on"
            case let .daemon(message): return message
            }
        }
    }

    public static func run(_ source: String, client: DaemonClient, focusSurface: String? = nil) throws {
        let command: Command
        do {
            command = try CommandParser.parse(source)
        } catch {
            throw Failure.parse("\(error)")
        }
        guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
            throw Failure.daemon("no snapshot from the daemon")
        }
        let options = OptionStore()
        let translation = CommandIPCTranslator.translate(
            command,
            target: target(snapshot, focusSurface: focusSurface),
            baseIndex: options.get("base-index")?.intValue ?? 0,
            paneBaseIndex: options.get("pane-base-index")?.intValue ?? 0
        )
        switch translation {
        case let .requests(requests):
            for request in requests {
                if case let .error(message) = try client.request(request) { throw Failure.daemon(message) }
            }
        case let .clientLocal(local):
            throw Failure.appOnly(local.shortDescription)
        case .unresolved:
            throw Failure.unresolved(command.shortDescription)
        }
    }

    /// The active chain, or the pane showing `focusSurface` (a script's own pane) when given.
    static func target(_ snapshot: SessionSnapshot, focusSurface: String?) -> CommandTarget {
        guard let focusSurface else { return CommandTarget(snapshot: snapshot) }
        for workspace in snapshot.workspaces {
            for tab in workspace.sessions.flatMap(\.tabs) {
                if let leaf = tab.rootPane.allLeaves().first(where: { $0.surfaceID.uuidString.caseInsensitiveCompare(focusSurface) == .orderedSame }) {
                    return CommandTarget(snapshot: snapshot, focusedWorkspaceID: workspace.id, focusedTabID: tab.id, focusedPaneID: leaf.id)
                }
            }
        }
        return CommandTarget(snapshot: snapshot)
    }
}
