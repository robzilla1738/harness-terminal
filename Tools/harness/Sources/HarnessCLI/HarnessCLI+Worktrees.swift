import Foundation
import HarnessCore

extension HarnessCLI {
    static func handleWorktree(_ args: [String], client: DaemonClient) throws {
        for flag in ["--id", "--repository", "--base", "--directory", "--offset", "--host"] where args.contains(flag) {
            guard let value = flagValue(args, flag: flag), !value.hasPrefix("--") else { throw NSError(domain: "HarnessWorktree", code: 2, userInfo: [NSLocalizedDescriptionKey: flag + " requires a value"]) }
        }
        if args.contains("--offset"), flagValue(args, flag: "--offset").flatMap(Int.init) == nil { throw NSError(domain: "HarnessWorktree", code: 2, userInfo: [NSLocalizedDescriptionKey: "--offset must be a nonnegative integer"]) }
        guard case let .daemonStats(stats) = try checkedRequest(client, .daemonStats), stats.supports(DaemonStats.managedWorktrees) else { throw NSError(domain: "HarnessWorktree", code: 2, userInfo: [NSLocalizedDescriptionKey: "Managed worktrees require a newer application daemon. Existing shells remain running during replacement."]) }
        let verb = args.count > 1 ? args[1] : "list", operation: WorktreeOperation
        switch verb {
        case "list": operation = .list(offset: flagValue(args, flag: "--offset").flatMap(Int.init) ?? 0, limit: 100)
        case "configure":
            operation = .configure(WorktreeSettings(directory: flagValue(args, flag: "--directory").map { ($0 as NSString).expandingTildeInPath }))
        case "create":
            guard let directory = flagValue(args, flag: "--repository") else { throw GitOperationError.path }
            let id = flagValue(args, flag: "--id").flatMap(UUID.init(uuidString:)) ?? UUID()
            if args.contains("--id"), flagValue(args, flag: "--id").flatMap(UUID.init(uuidString:)) == nil { throw ManagedWorktreeError.identity }
            fputs("Worktree operation ID: " + id.uuidString + "; retain it for inspection after any uncertain outcome.\n", harnessStderr)
            operation = .create(id: id, directory: (directory as NSString).expandingTildeInPath, base: flagValue(args, flag: "--base"))
        case "inspect", "compare", "remove", "difftool":
            guard let raw = flagValue(args, flag: "--id"), let id = UUID(uuidString: raw) else { throw ManagedWorktreeError.missing }
            if verb == "remove", !args.contains("--confirm") { throw NSError(domain: "HarnessWorktree", code: 2, userInfo: [NSLocalizedDescriptionKey: "Review worktree compare first, then use remove --id <UUID> --confirm. Cleanup protects dirty files, active processes and unpushed new commits; branches are retained."]) }
            switch verb { case "inspect": operation = .inspect(id: id); case "compare": operation = .compare(id: id); case "difftool": operation = .difftoolCommand(id: id); default: operation = .remove(id: id) }
        default: throw NSError(domain: "HarnessWorktree", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use worktree list|configure|create --repository path [--base committed-ref]|inspect|compare|difftool|remove --id UUID --confirm"])
        }
        let response = try checkedRequest(client, .activity(.worktrees(requestID: UUID(), operation: operation)), timeout: operation.requestTimeout)
        guard case let .text(json) = response else { throw DaemonClientError.unexpectedResponse }
        if verb == "difftool", !args.contains("--json"), let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String], let command = value["command"] { print(command) }
        else { print(json) }
    }
}
