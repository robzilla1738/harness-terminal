import Foundation
import HarnessCore

/// `ls`, `inspect`, `new`, `wait`, `keymap`, and `actions`: the everyday verbs, built on the
/// same snapshot, target context, and API executor as everything else.
extension HarnessCLI {
    /// `ls [--json]`: sessions → tabs → panes, with positions, short ids, and active marks.
    static func handleLs(_ args: [String], client: DaemonClient) throws {
        let snap = try snapshot(client)
        let inside = flagValue(args, flag: "--host") == nil && ProcessInfo.processInfo.environment["HARNESS_SURFACE"] != nil
        let tree = SessionTree.build(snap, context: targetContext(snap, args), callerInside: inside)
        try emit(tree, args) { print(tree.text()) }
    }

    /// `inspect [<pane>] [-s <session>] [--json]`: `session.view` or `pane.view`.
    static func handleInspect(_ args: [String], client: DaemonClient) throws {
        let call: (method: String, arguments: [String: APIArgument])
        if let session = flagValue(args, flag: "--session") {
            call = ("session.view", ["session": .string(session)])
        } else if let surface = flagValue(args, flag: "--surface") {
            call = ("pane.view", ["pane": .string(surface)])
        } else {
            fputs("Usage: harness-cli inspect [<pane>] [-s <session>] [--json]\n", harnessStderr)
            exit(CLIExit.usage)
        }
        let result = APIExecutor.call(method: call.method, arguments: call.arguments, client: client)
        guard let json = result.json else {
            fputs("inspect: \(result.message ?? "failed")\n", harnessStderr)
            exit(result.exitCode)
        }
        print(args.contains("--json") ? json : inspectText(json))
    }

    /// One `key  value` line per field; nested values stay compact JSON.
    static func inspectText(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return json }
        let rows = object.keys.sorted().map { key -> [String] in
            let value = object[key]
            switch value {
            case let text as String: return [key, text]
            case is NSNull, nil: return [key, "-"]
            case let number as NSNumber: return [key, number.stringValue]
            default:
                let data = (try? JSONSerialization.data(withJSONObject: value as Any, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
                return [key, String(decoding: data, as: UTF8.self)]
            }
        }
        return TextTable.render(["FIELD", "VALUE"], rows)
    }

    static let newUsage = "Usage: harness-cli new [<name>] [--cwd DIR] [--json] [-- COMMAND...]"

    /// `new [name] [--cwd DIR] [-- COMMAND...]`: a session in the caller's workspace. A
    /// command runs in its shell, so the session stays open when the command ends.
    static func handleNew(_ args: [String], client: DaemonClient) throws {
        let dashes = args.firstIndex(of: "--")
        let options = dashes.map { Array(args[..<$0]) } ?? args
        let command = dashes.map { ControlPlane.shellJoin(Array(args[($0 + 1)...])) } ?? ""
        let names = positionalArgs(options, skippingValuesFor: ["--cwd", "--host"])
        guard names.count <= 1 else {
            fputs(newUsage + "\n", harnessStderr)
            exit(CLIExit.usage)
        }
        let snap = try snapshot(client)
        guard let workspace = targetContext(snap, args).workspace else {
            fputs("new: no workspace\n", harnessStderr)
            exit(CLIExit.failed)
        }
        let cwd = flagValue(options, flag: "--cwd").map { ($0 as NSString).expandingTildeInPath }
        let response = try checkedRequest(client, .newSession(workspaceID: workspace.id, cwd: cwd, name: names.first))
        guard case let .sessionID(session) = response else { throw DaemonClientError.unexpectedResponse }
        let surface = try snapshot(client).workspaces.flatMap(\.sessions).first { $0.id == session }?
            .tabs.first?.rootPane.allLeaves().first?.surfaceID.uuidString
        if !command.isEmpty, let surface {
            _ = try checkedRequest(client, .send(surfaceID: surface, text: command + "\n"))
        }
        if args.contains("--json") {
            let body = ["session": session.uuidString, "surface": surface ?? ""]
            print(String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self))
        } else {
            print(session.uuidString)
        }
    }

    static let waitUsage = """
    Usage: harness-cli wait (--surface <pane> | -b <pane>) [--for DURATION] [--until child|command]
           harness-cli wait [-S|-L|-U] <channel>     (tmux wait-for)
    """

    /// `wait <channel>` is tmux's `wait-for`. With a pane instead, it waits for the pane's
    /// program to exit (or, with `--until command`, for its prompt to report a finished
    /// command) and exits with that status. `--for` gives up after a while (exit 1).
    static func handleWait(_ args: [String], client: DaemonClient) throws {
        let flagsWithValues: Set<String> = ["--surface", "--pane", "--for", "--until", "--host", "--timeout"]
        if !positionalArgs(args, skippingValuesFor: flagsWithValues).isEmpty {
            return try handleWaitFor(args, client: client)
        }
        guard let target = flagValue(args, flag: "--surface") ?? flagValue(args, flag: "--pane"),
              let pane = TargetContext.of(surface: target, in: try snapshot(client))?.pane
        else {
            fputs(waitUsage + "\n", harnessStderr)
            exit(CLIExit.usage)
        }
        let until = flagValue(args, flag: "--until") ?? "child"
        guard until == "child" || until == "command" else {
            fputs("wait: --until must be child or command\n", harnessStderr)
            exit(CLIExit.usage)
        }
        let limit = flagValue(args, flag: "--for") ?? flagValue(args, flag: "--timeout")
        guard let timeout = limit.map(CLIDuration.seconds) ?? 24 * 3600 else {
            fputs("wait: --for takes seconds or a number with s, m, or h (got '\(limit ?? "")')\n", harnessStderr)
            exit(CLIExit.usage)
        }
        waitForPane(client, surface: pane.surfaceID.uuidString, until: until, timeout: timeout, verb: "wait")
    }

    /// Blocks until the pane's program exits (`child`) or reports a finished command
    /// (`command`), then exits with its status. Shared by `wait` and `run --wait`.
    static func waitForPane(_ client: DaemonClient, surface: String, until: String, timeout: TimeInterval, verb: String) -> Never {
        do {
            // A waiting client can block for the whole run; give the socket the same budget.
            let response = try client.request(.paneWait(surfaceID: surface, until: until, timeout: timeout), timeout: timeout + 5)
            switch response {
            case let .text(body):
                struct ExitBody: Decodable { var exit: Int32 }
                exit((try? JSONDecoder().decode(ExitBody.self, from: Data(body.utf8)))?.exit ?? CLIExit.failed)
            case let .error(message):
                fputs("\(verb): \(message)\n", harnessStderr)
            default:
                fputs("\(verb): unexpected reply\n", harnessStderr)
            }
        } catch {
            fputs("\(verb): \(unreachableReason(error) ?? "\(error)")\n", harnessStderr)
            exit(unreachableReason(error) == nil ? CLIExit.failed : CLIExit.unreachable)
        }
        exit(CLIExit.failed)
    }

    /// `keymap [--json]`: every key from keybindings.json and the Lua config.
    static func handleKeymap(_ args: [String]) throws {
        let rows = KeymapRow.rows(tables: KeybindingsStore.load(), manifest: ScriptStore.load())
        try emit(rows, args) {
            print(TextTable.render(["KEY", "ACTION", "ARGS", "SOURCE"], rows.map { [$0.key, $0.action, $0.args, $0.source] }))
        }
    }

    /// `actions [--json]`: the config's Lua actions, then the built-in commands.
    static func handleActions(_ args: [String]) throws {
        let rows = ActionRow.rows(manifest: ScriptStore.load())
        try emit(rows, args) {
            print(TextTable.render(["NAME", "TITLE", "SOURCE"], rows.map { [$0.name, $0.title, $0.source] }))
        }
    }
}
