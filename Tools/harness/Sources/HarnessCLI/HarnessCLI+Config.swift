import Foundation
import HarnessCore

/// Options / environment / hooks / keybinding subcommands. Mechanically extracted from
/// `HarnessCLI.swift` (PR-32): zero logic change; one `private` helper relaxed to internal
/// for the file split.
extension HarnessCLI {
    /// Split `bind-key`/`unbind-key` args into the resolved table name and the remaining positional
    /// tokens (key spec + optional command source). Pure so it's unit-testable.
    ///
    /// The table comes from `-T <table>` and defaults to `prefix`. The strip of `-T`'s value must be
    /// gated on `-T` actually being present: otherwise `bind-key prefix <cmd>` (binding a key *named*
    /// `prefix`) had its literal `prefix` positional removed as if it were the default table value.
    static func parseKeyTableArgs(_ args: [String]) -> (table: String, positional: [String]) {
        let explicitTable = flagValue(args, flag: "-T")
        let table = explicitTable ?? "prefix"
        // Drop the subcommand at index 0; keep every other token so the command source can itself
        // contain flags (e.g. `new-window -h`).
        var positional = Array(args.dropFirst())
        positional.removeAll { $0 == "-T" }
        // Only strip the table token when it came from an explicit `-T <table>`; never when it's the
        // implicit default, or a literal key spec equal to "prefix" would be eaten.
        if explicitTable != nil, let i = positional.firstIndex(of: table) { positional.remove(at: i) }
        // tmux's `copy-mode-vi` is Harness's `copy-mode` — same mapping the parser
        // applies, so a CLI bind never lands in a phantom table no client consults.
        return (CommandParser.canonicalTableName(table), positional)
    }

    static func handleBindKey(_ args: [String]) throws {
        // Usage: harness-cli bind-key [-T <table>] <spec> <command source>
        let (table, positional) = parseKeyTableArgs(args)
        guard positional.count >= 2 else {
            fputs("Usage: harness-cli bind-key [-T <table>] <spec> <command...>\n", harnessStderr)
            exit(1)
        }
        let spec = positional[0]
        let source = positional.dropFirst().joined(separator: " ")
        guard let parsedSpec = KeySpec.parse(spec) else {
            fputs("Invalid key spec: \(spec)\n", harnessStderr)
            exit(1)
        }
        let command = try CommandParser.parse(source)
        var set = KeybindingsStore.load()
        set.setBinding(table: KeyTableID(rawValue: table), binding: Binding(spec: parsedSpec, command: command))
        let url = try KeybindingsStore.save(set)
        print(url.path)
    }

    static func handleUnbindKey(_ args: [String]) throws {
        let (table, positional) = parseKeyTableArgs(args)
        guard let spec = positional.first, let parsedSpec = KeySpec.parse(spec) else {
            fputs("Usage: harness-cli unbind-key [-T <table>] <spec>\n", harnessStderr)
            exit(1)
        }
        var set = KeybindingsStore.load()
        set.removeBinding(table: KeyTableID(rawValue: table), spec: parsedSpec)
        let url = try KeybindingsStore.save(set)
        print(url.path)
    }

    static func handleSetOption(_ args: [String], defaultScope: String, client: DaemonClient) throws {
        // Usage: set-option [-g|-w|-s|-t|-p] [-T <target>] <key> <value>
        var scope = defaultScope
        if args.contains("-g") { scope = "global" }
        if args.contains("-w") { scope = "workspace" }
        if args.contains("-s") { scope = "session" }
        if args.contains("-t") { scope = "tab" }
        if args.contains("-p") { scope = "pane" }
        var target = flagValue(args, flag: "-T")
        // Scoped options resolve by exact target — a nil-target workspace/session/tab/pane
        // entry is stored but unreachable by every read path (the fallback chain only widens
        // toward global). Without -T, resolve the target from the calling pane
        // ($HARNESS_SURFACE — tmux: scoped sets apply to the current window); outside
        // a Harness pane, require -T instead of silently writing a dead option.
        if scope != "global", target == nil {
            target = callingPaneTarget(scope: scope, client: client)
        }
        if scope != "global", target == nil {
            fputs("set-option: \(scope) scope requires -T <target> (or run inside a Harness pane)\n", harnessStderr)
            exit(1)
        }
        // `positionalArgs` skips the subcommand at index 0 plus `-T <target>` (and any
        // lone scope flags), so `<key>` isn't mis-read as the subcommand name.
        let positional = positionalArgs(args, skippingValuesFor: ["-T"])
        guard positional.count >= 2 else {
            fputs("Usage: harness-cli set-option [-g|-w|-s|-t|-p] [-T <target>] <key> <value>\n", harnessStderr)
            exit(1)
        }
        let key = positional[0]
        let value = positional.dropFirst().joined(separator: " ")
        _ = try checkedRequest(client, .setOption(scope: scope, target: target, key: key, rawValue: value))
    }

    /// The calling pane's workspace/session/tab/pane ID for a scoped option write —
    /// the CLI's "focus" when it runs inside a Harness pane ($HARNESS_SURFACE).
    /// nil outside a pane or when the surface is gone from the snapshot.
    static func callingPaneTarget(scope: String, client: DaemonClient) -> String? {
        guard let surface = ProcessInfo.processInfo.environment["HARNESS_SURFACE"],
              let surfaceID = UUID(uuidString: surface),
              case let .snapshot(snapshot)? = try? client.request(.getSnapshot, timeout: 2)
        else { return nil }
        for workspace in snapshot.workspaces {
            for session in workspace.sessions {
                for tab in session.tabs where tab.rootPane.allSurfaceIDs().contains(surfaceID) {
                    switch scope {
                    case "workspace": return workspace.id.uuidString
                    case "session": return session.id.uuidString
                    case "tab": return tab.id.uuidString
                    case "pane":
                        return tab.rootPane.allLeaves().first { $0.surfaceID == surfaceID }?.id.uuidString
                    default: return nil
                    }
                }
            }
        }
        return nil
    }

    static func handleShowOptions(_ args: [String], client: DaemonClient) throws {
        var scope: String?
        if args.contains("-g") { scope = "global" }
        if args.contains("-w") { scope = "workspace" }
        if args.contains("-s") { scope = "session" }
        if args.contains("-t") { scope = "tab" }
        if args.contains("-p") { scope = "pane" }
        let response = try checkedRequest(client, .showOptions(scope: scope))
        guard case let .options(items) = response else { throw DaemonClientError.unexpectedResponse }
        let sorted = items.sorted(by: { $0.key < $1.key })
        try emit(sorted, args) {
            for item in sorted {
                let prefix = item.target.map { "\(item.scope):\($0)" } ?? item.scope
                print("\(prefix)\t\(item.key)\t\(item.value)")
            }
        }
    }

    /// Resolve a `-s <name|uuid>` environment target to a session ID, or exit. An invalid
    /// target must NEVER fall through to nil: the IPC contract treats `sessionID == nil` as
    /// the GLOBAL environment, so a typo'd session would silently inject the variable (often
    /// a secret) into every new pane on the machine.
    static func requireSessionID(_ nameOrID: String, client: DaemonClient, command: String) throws -> SessionID {
        if let session = resolveSession(try snapshot(client), nameOrID: nameOrID) { return session.id }
        fputs("\(command): no session matches '\(nameOrID)'\n", harnessStderr)
        exit(1)
    }

    static func handleSetEnvironment(_ args: [String], client: DaemonClient) throws {
        // Usage: set-environment [-g] [-u] [-s <session name|uuid>] <key> [value]
        // -g = global (default when no -s); -u = unset; -s targets a session.
        let global = args.contains("-g")
        let unset = args.contains("-u")
        // A dangling `-s` (last token, no value) collapses to nil in flagValue, which would
        // bypass requireSessionID and fall through to the GLOBAL environment — the exact
        // secret-leak fail-open requireSessionID's own comment forbids. Reject it loudly.
        if !global, flagIsDangling(args, flag: "-s") {
            fputs("set-environment: -s requires a <session name|uuid>\n", harnessStderr)
            exit(1)
        }
        let sessionRaw = global ? nil : flagValue(args, flag: "-s")
        let sessionID = try sessionRaw.map { try requireSessionID($0, client: client, command: "set-environment") }
        // `positionalArgs` skips the subcommand at index 0 plus `-s <session>` (and lone
        // flags like `-g`/`-u`), so `<key>` isn't mis-read as the subcommand name.
        let positional = positionalArgs(args, skippingValuesFor: ["-s"])
        guard let key = positional.first else {
            fputs("Usage: harness-cli set-environment [-g] [-u] [-s <session name|uuid>] <key> [value]\n", harnessStderr)
            exit(1)
        }
        let value = unset ? nil : positional.dropFirst().joined(separator: " ")
        _ = try checkedRequest(client, .setEnvironment(sessionID: sessionID, key: key, value: value))
    }

    static func handleShowEnvironment(_ args: [String], client: DaemonClient) throws {
        // Same dangling-`-s` guard as set-environment: a truncated `-s` must not silently
        // read the global environment instead of the intended session's.
        if !args.contains("-g"), flagIsDangling(args, flag: "-s") {
            fputs("show-environment: -s requires a <session name|uuid>\n", harnessStderr)
            exit(1)
        }
        let sessionRaw = args.contains("-g") ? nil : flagValue(args, flag: "-s")
        let sessionID = try sessionRaw.map { try requireSessionID($0, client: client, command: "show-environment") }
        let response = try checkedRequest(client, .showEnvironment(sessionID: sessionID))
        guard case let .options(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                print("\(item.key)=\(item.value)")
            }
        }
    }

    static func handleBindHook(_ args: [String], client: DaemonClient) throws {
        // Drop the subcommand (`bind-hook`) at index 0: `<event> <command...> [--if <format>]`.
        guard let parsed = parseBindHook(Array(args.dropFirst())) else {
            fputs("Usage: harness-cli bind-hook <event> <command...> [--if <format>]\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(
            client, .bindHook(event: parsed.event, source: parsed.source, condition: parsed.condition))
        if case let .hookID(id) = response { print(id.uuidString) }
    }

    /// Parse `<event> <command...> [--if <format>]` (the args after the `bind-hook` subcommand).
    /// Returns nil for any malformed shape so the caller can print usage once:
    ///   - fewer than two tokens (no command);
    ///   - `--if` at index 0 (no event) or index 1 (empty command) — the latter also closes the
    ///     `rest[1..<ifIndex]` crash where `ifIndex < 1` slices an inverted range and traps.
    static func parseBindHook(_ rest: [String]) -> (event: String, source: String, condition: String?)? {
        guard rest.count >= 2 else { return nil }
        let event = rest[0]
        let ifIndex = rest.firstIndex(of: "--if")
        if let ifIndex {
            // Need an event (index 0) and at least one command token before `--if` (index >= 2),
            // plus a format token after it.
            guard ifIndex > 1, rest.count > ifIndex + 1 else { return nil }
            return (event, rest[1..<ifIndex].joined(separator: " "), rest[ifIndex + 1])
        }
        return (event, rest.dropFirst().joined(separator: " "), nil)
    }

    static func handleUnbindHook(_ args: [String], client: DaemonClient) throws {
        guard let raw = flagValue(args, flag: "--id"), let id = UUID(uuidString: raw) else {
            fputs("Usage: harness-cli unbind-hook --id <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .unbindHook(id: id))
    }

    static func handleListHooks(_ args: [String], client: DaemonClient) throws {
        let event = flagValue(args, flag: "--event")
        let response = try checkedRequest(client, .listHooks(event: event))
        guard case let .hooks(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                let cond = item.condition.map { " if '\($0)'" } ?? ""
                print("\(item.id.uuidString)\t\(item.event)\t\(item.commandSource)\(cond)")
            }
        }
    }

    static func handleDisplayMessage(_ args: [String], client: DaemonClient) throws {
        // Drop the subcommand at index 0 so it doesn't leak into the format string.
        let rest = Array(args.dropFirst())
        let printMode = rest.contains("-p") // tmux `-p`: print the rendered text to stdout
        let format = rest.filter { $0 != "-p" }.joined(separator: " ")
        guard !format.isEmpty else {
            fputs("Usage: harness-cli display-message [-p] <format>\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .displayMessage(format: format, print: printMode))
        if printMode, case let .text(rendered) = response {
            print(rendered)
        }
    }

    static func handleListKeys(_ args: [String]) throws {
        let tableFlag = flagValue(args, flag: "-T")
        let set = KeybindingsStore.load()
        let chosen: [KeyTable] = tableFlag.map {
            [set.table(KeyTableID(rawValue: CommandParser.canonicalTableName($0)))].compactMap { $0 }
        } ?? set.tableList
        for table in chosen {
            print("[\(table.id.rawValue)]")
            for binding in table.bindings {
                let note = binding.note.map { "  -- \($0)" } ?? ""
                print("  \(binding.spec.description)\t\(binding.command.shortDescription)\(note)")
            }
        }
    }
}
