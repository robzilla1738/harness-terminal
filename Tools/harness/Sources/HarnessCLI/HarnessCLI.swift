#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore
import HarnessTheme

@main
struct HarnessCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }
        do {
            switch command {
            case "color-check":
                printColorCheck(args)
                return
            case "theme-preview":
                printThemePreview(args)
                return
            case "remote":
                exit(try handleRemote(args))
            case "daemon":
                runDaemonForeground() // execs HarnessDaemon; never returns
            case "version", "--version", "-v":
                printVersion(args) // best-effort daemon query; works with the daemon down
                return
            default:
                break
            }

            let client = try makeClient(args)
            switch command {
            case "list-workspaces":
                try printWorkspaces(args, client: client)
            case "list-surfaces":
                try printSurfaces(args, client: client)
            case "list-sessions":
                try printSessions(args, client: client)
            case "list-agents":
                try printAgents(args, client: client)
            case "doctor":
                try runDoctor(args, client: client)   // exits with its own status
            case "completions":
                try printCompletions(args)
            case "list-windows":
                try printWindows(args, client: client)
            case "list-panes":
                try printPanes(args, client: client)
            case "has-session":
                try handleHasSession(args, client: client)   // exits with status, prints nothing
            case "list-commands":
                CommandParser.knownVerbs.forEach { print($0) }
            case "get-snapshot":
                try printSnapshot(client)
            case "new-workspace":
                let name = flagValue(args, flag: "--name") ?? "Workspace"
                let response = try checkedRequest(client, .newWorkspace(name: name))
                if case let .workspaceID(id) = response { print(id.uuidString) }
            case "new-session":
                try handleNewSession(args, client: client)
            case "new-tab":
                try handleNewTab(args, client: client)
            case "new-split":
                try handleNewSplit(args, client: client)
            case "select-workspace":
                try handleSelectWorkspace(args, client: client)
            case "select-tab":
                try handleSelectTab(args, client: client)
            case "select-session":
                try handleSelectSession(args, client: client)
            case "close-tab":
                guard let tabID = UUID(uuidString: flagValue(args, flag: "--tab") ?? "") else {
                    fputs("Usage: harness-cli close-tab --tab <uuid>\n", harnessStderr)
                    exit(1)
                }
                _ = try checkedRequest(client, .closeTab(tabID: tabID))
            case "close-session":
                guard let sessionID = UUID(uuidString: flagValue(args, flag: "--session") ?? "") else {
                    fputs("Usage: harness-cli close-session --session <uuid>\n", harnessStderr)
                    exit(1)
                }
                _ = try checkedRequest(client, .closeSession(sessionID: sessionID))
            case "promote-session", "demote-session":
                guard let sessionID = UUID(uuidString: flagValue(args, flag: "--session") ?? "") else {
                    fputs("Usage: harness-cli \(command) --session <uuid>\n", harnessStderr)
                    exit(1)
                }
                // Promote pins a session to survive a clean quit even in Plain mode; demote
                // makes it ephemeral again.
                _ = try checkedRequest(client, .setSessionPersistent(sessionID: sessionID, persistent: command == "promote-session"))
            case "send":
                guard let surface = flagValue(args, flag: "--surface"),
                      let text = flagValue(args, flag: "--text")
                else {
                    fputs("Usage: harness-cli send --surface <uuid> --text \"...\"\n", harnessStderr)
                    exit(1)
                }
                _ = try checkedRequest(client, .send(surfaceID: surface, text: text))
            case "notify":
                guard let surface = flagValue(args, flag: "--surface") else {
                    fputs("Usage: harness-cli notify --surface <uuid> [--title t] [--body b] [--from-hook]\n", harnessStderr)
                    exit(1)
                }
                let title = flagValue(args, flag: "--title") ?? "Agent"
                let fallbackBody = flagValue(args, flag: "--body") ?? flagValue(args, flag: "--message")
                // `--from-hook`: read the agent's notification payload (JSON) from stdin and use
                // its `message` for the body. Gated behind the flag (like `set-buffer --stdin`)
                // so an interactive `notify` never blocks on `readDataToEndOfFile`. Claude Code's
                // `Notification` hook delivers the message this way — not via an env var.
                // Both paths resolve through HookNotificationParser so the default body lives in
                // one place; only `--from-hook` reads stdin, otherwise we resolve with no payload.
                let parsed = args.contains("--from-hook")
                    ? HookNotificationParser.parse(FileHandle.standardInput.readDataToEndOfFile())
                    : nil
                let body = HookNotificationParser.resolveBody(parsed: parsed, fallbackBody: fallbackBody)
                _ = try checkedRequest(client, .notify(surfaceID: surface, title: title, body: body))
            case "install":
                try installCLI()
            case "ping":
                let response = try checkedRequest(client, .ping)
                print(response)
            case "send-keys":
                try handleSendKeys(args, client: client)
            case "capture-pane":
                try handleCapturePane(args, client: client)
            case "pipe-pane":
                try handlePipePane(args, client: client)
            case "wait-for", "wait":
                try handleWaitFor(args, client: client)
            case "link-window":
                try handleLinkWindow(args, client: client)
            case "unlink-window":
                try handleUnlinkWindow(args, client: client)
            case "control-mode", "-CC":
                exit(try ControlModeClient.run(client: client))
            case "kill-pane":
                try handlePaneCommand(args, client: client) { paneID in .killPane(paneID: paneID) }
            case "swap-pane":
                try handleSwapPane(args, client: client)
            case "resize-pane":
                try handleResizePane(args, client: client)
            case "zoom-pane":
                try handlePaneCommand(args, client: client) { paneID in .zoomPane(paneID: paneID) }
            case "copy-mode":
                try handleCopyMode(args, client: client)
            case "rename-tab":
                try handleRenameTab(args, client: client)
            case "rename-session":
                try handleRenameSession(args, client: client)
            case "rename-workspace":
                try handleRenameWorkspace(args, client: client)
            case "detect-agent":
                try handleDetectAgent(args, client: client)
            case "install-hooks":
                try handleInstallHooks(args)
            case "install-shell-integration":
                handleInstallShellIntegration(args)
            case "attach":
                let code = try handleAttach(args)
                exit(code)
            case "attach-window":
                #if canImport(HarnessTerminalKit)
                let code = try handleAttachWindow(args)
                exit(code)
                #else
                // The window compositor needs the Metal/AppKit terminal kit, which isn't built on
                // headless/Linux. Single-pane `attach` still works there.
                fputs("harness-cli attach-window: not supported on this platform; use `attach`\n", harnessStderr)
                exit(64)
                #endif
            case "record":
                exit(handleRecord(args, client: client))
            case "replay":
                exit(handleReplay(args))
            case "daemon-stats":
                try printDaemonStats(args, client: client)
            case "list-clients":
                try printClients(args, client: client)
            case "detach-client":
                try handleDetachClient(args, client: client)
            case "bind-key", "bind":
                try handleBindKey(args)
            case "unbind-key", "unbind":
                try handleUnbindKey(args)
            case "list-keys":
                try handleListKeys(args)
            case "set-buffer":
                try handleSetBuffer(args, client: client)
            case "list-buffers":
                try handleListBuffers(args, client: client)
            case "show-buffer":
                try handleShowBuffer(args, client: client)
            case "delete-buffer":
                try handleDeleteBuffer(args, client: client)
            case "paste-buffer":
                try handlePasteBuffer(args, client: client)
            case "save-buffer":
                try handleSaveBuffer(args, client: client)
            case "load-buffer":
                try handleLoadBuffer(args, client: client)
            case "select-layout":
                try handleSelectLayout(args, client: client)
            case "next-layout":
                try handleCycleLayout(args, client: client, forward: true)
            case "previous-layout":
                try handleCycleLayout(args, client: client, forward: false)
            case "rotate-window":
                try handleRotateWindow(args, client: client)
            case "break-pane":
                try handleBreakPane(args, client: client)
            case "join-pane":
                try handleJoinPane(args, client: client)
            case "move-pane":
                try handleMovePane(args, client: client)
            case "renumber-windows":
                try handleRenumberWindows(args, client: client)
            case "respawn-pane":
                try handleRespawnPane(args, client: client)
            case "select-pane":
                try handleSelectPane(args, client: client)
            case "set-option", "setw":
                try handleSetOption(args, client: client)
            case "show-options":
                try handleShowOptions(args, client: client)
            case "set-environment", "setenv":
                try handleSetEnvironment(args, client: client)
            case "show-environment", "showenv":
                try handleShowEnvironment(args, client: client)
            case "bind-hook":
                try handleBindHook(args, client: client)
            case "unbind-hook":
                try handleUnbindHook(args, client: client)
            case "list-hooks":
                try handleListHooks(args, client: client)
            case "display-message":
                try handleDisplayMessage(args, client: client)
            default:
                printUsage()
                exit(1)
            }
        } catch {
            fputs("harness-cli: \(error)\n", harnessStderr)
            exit(1)
        }
    }

    static func printColorCheck(_ args: [String]) {
        print(ThemeDiagnostics.colorCheck(), terminator: "")
    }

    static func printThemePreview(_ args: [String]) {
        if args.contains("--all") {
            for (index, theme) in HarnessThemeCatalog.allThemes.enumerated() {
                if index > 0 { print("") }
                print(ThemeDiagnostics.themePreview(theme), terminator: "")
            }
            return
        }

        let themeName = flagValue(args, flag: "--theme") ?? HarnessThemeCatalog.defaultThemeName
        guard let theme = HarnessThemeCatalog.theme(named: themeName) else {
            fputs("Unknown theme: \(themeName)\n", harnessStderr)
            exit(1)
        }
        print(ThemeDiagnostics.themePreview(theme), terminator: "")
    }

    static func handleNewTab(_ args: [String], client: DaemonClient) throws {
        if let name = flagValue(args, flag: "--workspace") {
            let cwd = flagValue(args, flag: "--cwd")
            let response = try checkedRequest(client, .newTabInWorkspace(named: name, cwd: cwd))
            if case let .tabID(id) = response { print(id.uuidString) }
            return
        }
        guard let workspaceID = UUID(uuidString: flagValue(args, flag: "--workspace-id") ?? "") else {
            fputs("Usage: harness-cli new-tab --workspace <name|uuid> [--cwd path]\n", harnessStderr)
            exit(1)
        }
        let cwd = flagValue(args, flag: "--cwd")
        let response = try checkedRequest(client, .newTab(workspaceID: workspaceID, cwd: cwd))
        if case let .tabID(id) = response { print(id.uuidString) }
    }

    static func handleNewSession(_ args: [String], client: DaemonClient) throws {
        guard let workspaceID = try resolveWorkspaceID(args, client: client) else {
            fputs("Usage: harness-cli new-session --workspace <name|uuid> [--cwd path] [--name name]\n", harnessStderr)
            exit(1)
        }
        let cwd = flagValue(args, flag: "--cwd")
        let name = flagValue(args, flag: "--name")
        let response = try checkedRequest(client, .newSession(workspaceID: workspaceID, cwd: cwd, name: name))
        if case let .sessionID(id) = response { print(id.uuidString) }
    }

    static func handleNewSplit(_ args: [String], client: DaemonClient) throws {
        guard let tabID = UUID(uuidString: flagValue(args, flag: "--tab") ?? ""),
              let directionRaw = flagValue(args, flag: "--direction"),
              let direction = SplitDirection(rawValue: directionRaw)
        else {
            fputs("Usage: harness-cli new-split --tab <uuid> --direction horizontal|vertical\n", harnessStderr)
            exit(1)
        }
        let paneID: UUID?
        switch optionalUUIDFlag(args, flag: "--pane") {
        case .absent: paneID = nil
        case .valid(let id): paneID = id
        case .invalid(let raw):
            fputs("new-split: --pane must be a pane UUID (got '\(raw)')\n", harnessStderr)
            exit(1)
        case .dangling:
            fputs("new-split: --pane requires a value\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .newSplit(tabID: tabID, paneID: paneID, direction: direction))
        if case let .paneID(id) = response { print(id.uuidString) }
    }

    static func handleSelectWorkspace(_ args: [String], client: DaemonClient) throws {
        guard let target = flagValue(args, flag: "--workspace") ?? flagValue(args, flag: "--id") else {
            fputs("Usage: harness-cli select-workspace --workspace <name|uuid>\n", harnessStderr)
            exit(1)
        }
        if let uuid = UUID(uuidString: target) {
            _ = try checkedRequest(client, .selectWorkspace(id: uuid))
        } else {
            _ = try checkedRequest(client, .selectWorkspaceByName(name: target))
        }
    }

    static func handleSelectTab(_ args: [String], client: DaemonClient) throws {
        guard let workspaceID = UUID(uuidString: flagValue(args, flag: "--workspace") ?? ""),
              let tabID = UUID(uuidString: flagValue(args, flag: "--tab") ?? "")
        else {
            fputs("Usage: harness-cli select-tab --workspace <uuid> --tab <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .selectTab(workspaceID: workspaceID, tabID: tabID))
    }

    static func handleSelectSession(_ args: [String], client: DaemonClient) throws {
        guard let workspaceID = try resolveWorkspaceID(args, client: client),
              let sessionID = UUID(uuidString: flagValue(args, flag: "--session") ?? "")
        else {
            fputs("Usage: harness-cli select-session --workspace <name|uuid> --session <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .selectSession(workspaceID: workspaceID, sessionID: sessionID))
    }

    static func printWorkspaces(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .listWorkspaces)
        guard case let .workspaces(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                print("\(item.id)\t\(item.name)\t\(item.tabCount) sessions")
            }
        }
    }

    static func printSurfaces(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .listSurfaces)
        guard case let .surfaces(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                print("\(item.surfaceID)\t\(item.workspaceName)\t\(item.tabTitle)\t\(item.cwd)")
            }
        }
    }

    static func resolveWorkspaceID(_ args: [String], client: DaemonClient) throws -> UUID? {
        guard let target = flagValue(args, flag: "--workspace") ?? flagValue(args, flag: "--workspace-id") else {
            return nil
        }
        if let uuid = UUID(uuidString: target) {
            return uuid
        }
        let response = try checkedRequest(client, .listWorkspaces)
        guard case let .workspaces(items) = response else { return nil }
        return items.first { $0.name == target }?.id
    }

    private static func snapshot(_ client: DaemonClient) throws -> SessionSnapshot {
        guard case let .snapshot(snapshot) = try checkedRequest(client, .getSnapshot) else {
            throw DaemonClientError.unexpectedResponse
        }
        return snapshot
    }

    static func printSessions(_ args: [String], client: DaemonClient) throws {
        let snap = try snapshot(client)
        try emit(SnapshotQueryFormatter.sessionRows(snap), args) {
            SnapshotQueryFormatter.sessions(snap).forEach { print($0) }
        }
    }

    /// `list-agents [--waiting] [--json] [--pretty]` — every running agent with its
    /// workspace/session/tab/pane, surface id, name, state, and last-activity age.
    /// `--waiting` filters to agents blocking on you; `--json` emits the machine-readable shape.
    static func printAgents(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .listAgents)
        guard case let .agents(items) = response else { throw DaemonClientError.unexpectedResponse }
        let filtered = args.contains("--waiting") ? items.filter(\.waiting) : items
        try emit(filtered, args) {
            AgentListFormatter.text(filtered).forEach { print($0) }
        }
    }

    /// `list-windows [--session <name|uuid>]` — all tabs, or one session's when targeted.
    /// A provided-but-unresolvable target is a hard error, never a silent fall-back to all
    /// windows — scripts must not receive plausible-but-wrong data for a typo'd target.
    static func printWindows(_ args: [String], client: DaemonClient) throws {
        let snap = try snapshot(client)
        if let target = flagValue(args, flag: "--session") {
            guard let session = resolveSession(snap, nameOrID: target) else {
                fputs("list-windows: no session matches '\(target)'\n", harnessStderr)
                exit(1)
            }
            try emit(SnapshotQueryFormatter.windowRows(in: session), args) {
                SnapshotQueryFormatter.windows(in: session).forEach { print($0) }
            }
        } else {
            try emit(SnapshotQueryFormatter.windowRows(snap), args) {
                SnapshotQueryFormatter.windows(snap).forEach { print($0) }
            }
        }
    }

    /// `list-panes [--tab <uuid>]` — panes of the targeted tab, or the active tab. A malformed
    /// `--tab` is a hard error, never a silent fall-back to the active tab (see list-windows).
    static func printPanes(_ args: [String], client: DaemonClient) throws {
        let snap = try snapshot(client)
        let tab: Tab?
        if let raw = flagValue(args, flag: "--tab") {
            guard let tabID = UUID(uuidString: raw) else {
                fputs("list-panes: --tab must be a tab UUID (got '\(raw)')\n", harnessStderr)
                exit(1)
            }
            tab = snap.workspaces.flatMap(\.sessions).flatMap(\.tabs).first { $0.id == tabID }
        } else {
            tab = snap.activeWorkspace?.activeTab
        }
        guard let tab else {
            fputs("list-panes: no matching tab\n", harnessStderr)
            exit(1)
        }
        try emit(SnapshotQueryFormatter.paneRows(in: tab), args) {
            SnapshotQueryFormatter.panes(in: tab).forEach { print($0) }
        }
    }

    /// `has-session --session <name|uuid>` — tmux scripting verb: exit 0 if it exists, 1 if not,
    /// printing nothing (so `if harness-cli has-session …` works in shell scripts).
    static func handleHasSession(_ args: [String], client: DaemonClient) throws {
        guard let target = flagValue(args, flag: "--session") else {
            fputs("Usage: harness-cli has-session --session <name|uuid>\n", harnessStderr)
            exit(2)
        }
        let exists = SnapshotQueryFormatter.sessionExists(try snapshot(client), nameOrID: target)
        exit(exists ? 0 : 1)
    }

    private static func resolveSession(_ snapshot: SessionSnapshot, nameOrID: String) -> SessionGroup? {
        let lowered = nameOrID.lowercased()
        return snapshot.workspaces.flatMap(\.sessions).first {
            $0.id.uuidString.lowercased() == lowered || $0.name == nameOrID
        }
    }

    static func printSnapshot(_ client: DaemonClient) throws {
        let response = try checkedRequest(client, .getSnapshot)
        guard case let .snapshot(snapshot) = response else { throw DaemonClientError.unexpectedResponse }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        if let text = String(data: data, encoding: .utf8) { print(text) }
    }

    static func handleSendKeys(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface"),
              let keys = flagValue(args, flag: "--keys")
        else {
            fputs("Usage: harness-cli send-keys --surface <id> [-l|-H] --keys \"C-c Up Enter ...\"\n", harnessStderr)
            exit(1)
        }
        // `-l` (literal): send the keys text verbatim, no key-name interpretation.
        // `-H` (hex): each token is a hex byte. Both go through `sendData` (raw bytes).
        if args.contains("-l") || args.contains("--literal") {
            _ = try checkedRequest(client, .sendData(surfaceID: surface, data: Data(keys.utf8)))
            return
        }
        let tokens = keys.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if args.contains("-H") || args.contains("--hex") {
            _ = try checkedRequest(client, .sendData(surfaceID: surface, data: KeyTokenParser.hexBytes(tokens)))
            return
        }
        _ = try checkedRequest(client, .sendKeys(surfaceID: surface, keys: tokens))
    }

    static func handleCapturePane(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli capture-pane --surface <id> [--scrollback] [-S <start>] [-E <end>] [-e] [-J] [-p]\n", harnessStderr)
            exit(1)
        }
        // -S/-E request a line range (tmux `-p` prints to stdout, the default here);
        // negative numbers count back from the bottom. -e keeps the program's raw escapes;
        // -J joins soft-wrapped lines (grid-reconstructed plain text).
        let start = flagValue(args, flag: "-S").flatMap(Int.init)
        let end = flagValue(args, flag: "-E").flatMap(Int.init)
        let escapes = args.contains("-e")
        let join = args.contains("-J")
        let response: IPCResponse
        if args.contains("-S") || args.contains("-E") || escapes || join || args.contains("-p") {
            response = try checkedRequest(client, .capturePaneRange(surfaceID: surface, start: start, end: end, escapeSequences: escapes, joinWrapped: join))
        } else {
            response = try checkedRequest(client, .capturePane(surfaceID: surface, includeScrollback: args.contains("--scrollback")))
        }
        if case let .text(text) = response { print(text) }
    }

    static func handlePipePane(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli pipe-pane --surface <id> [<shell-command>]   (omit command to stop)\n", harnessStderr)
            exit(1)
        }
        // Skip the subcommand at index 0; the first remaining non-flag, non-surface
        // token is the shell command (omitted → stop piping).
        let command = args.dropFirst().first { !$0.hasPrefix("-") && $0 != surface }
        _ = try checkedRequest(client, .pipePane(surfaceID: surface, shellCommand: command))
    }

    /// `wait-for [-S|-L|-U] <channel>` — tmux named-channel sync. Plain `wait-for` blocks
    /// until another client `-S` signals it; `-L`/`-U` lock/unlock.
    static func handleWaitFor(_ args: [String], client: DaemonClient) throws {
        let mode: String
        if args.contains("-S") { mode = "signal" }
        else if args.contains("-L") { mode = "lock" }
        else if args.contains("-U") { mode = "unlock" }
        else { mode = "wait" }
        guard let channel = positionalArgs(args, skippingValuesFor: []).first else {
            fputs("Usage: harness-cli wait-for [-S|-L|-U] <channel>\n", harnessStderr)
            exit(1)
        }
        // `wait`/`lock` block until signaled/granted — a generous (≈1 week) timeout, well
        // within the poll's Int32 millisecond range. `signal`/`unlock` return at once.
        let timeout: TimeInterval = (mode == "wait" || mode == "lock") ? 604_800 : 5
        _ = try checkedRequest(client, .waitFor(channel: channel, mode: mode), timeout: timeout)
    }

    static func handleLinkWindow(_ args: [String], client: DaemonClient) throws {
        guard let tabRaw = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabRaw),
              let sessionRaw = flagValue(args, flag: "--target-session"), let sessionID = UUID(uuidString: sessionRaw) else {
            fputs("Usage: harness-cli link-window --tab <uuid> --target-session <uuid>\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .linkWindow(tabID: tabID, targetSessionID: sessionID))
        if case let .tabID(id) = response { print(id.uuidString) }
    }

    static func handleUnlinkWindow(_ args: [String], client: DaemonClient) throws {
        guard let tabRaw = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabRaw) else {
            fputs("Usage: harness-cli unlink-window --tab <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .unlinkWindow(tabID: tabID))
    }

    static func handlePaneCommand(_ args: [String], client: DaemonClient, _ make: (UUID) -> IPCRequest) throws {
        guard let paneIDStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneIDStr) else {
            fputs("Missing or invalid --pane <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, make(paneID))
    }

    static func handleSwapPane(_ args: [String], client: DaemonClient) throws {
        guard let srcStr = flagValue(args, flag: "--src"), let src = UUID(uuidString: srcStr),
              let dstStr = flagValue(args, flag: "--dst"), let dst = UUID(uuidString: dstStr)
        else {
            fputs("Usage: harness-cli swap-pane --src <uuid> --dst <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .swapPanes(srcPaneID: src, dstPaneID: dst))
    }

    static func handleResizePane(_ args: [String], client: DaemonClient) throws {
        guard let paneStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneStr),
              let dirStr = flagValue(args, flag: "--dir")?.lowercased(),
              let direction = parseDirection(dirStr)
        else {
            fputs("Usage: harness-cli resize-pane --pane <uuid> --dir L|R|U|D [--amount N]\n", harnessStderr)
            exit(1)
        }
        let amount = Int(flagValue(args, flag: "--amount") ?? "1") ?? 1
        _ = try checkedRequest(client, .resizePane(paneID: paneID, direction: direction, amount: amount))
    }

    static func parseDirection(_ raw: String) -> ResizeDirection? {
        switch raw {
        case "l", "left": return .left
        case "r", "right": return .right
        case "u", "up": return .up
        case "d", "down": return .down
        default: return nil
        }
    }

    static func handleCopyMode(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli copy-mode --surface <id> [--enter|--exit]\n", harnessStderr)
            exit(1)
        }
        let enabled = !args.contains("--exit")
        _ = try checkedRequest(client, .setCopyMode(surfaceID: surface, enabled: enabled))
    }

    static func handleRenameTab(_ args: [String], client: DaemonClient) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-tab --tab <uuid> --name \"...\"\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renameTab(tabID: tabID, name: name))
    }

    static func handleRenameSession(_ args: [String], client: DaemonClient) throws {
        guard let sessionStr = flagValue(args, flag: "--session"), let sessionID = UUID(uuidString: sessionStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-session --session <uuid> --name \"...\"\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renameSession(sessionID: sessionID, name: name))
    }

    static func handleRenameWorkspace(_ args: [String], client: DaemonClient) throws {
        guard let idStr = flagValue(args, flag: "--id") ?? flagValue(args, flag: "--workspace"),
              let id = UUID(uuidString: idStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-workspace --id <uuid> --name \"...\"\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renameWorkspace(workspaceID: id, name: name))
    }

    static func handleDetectAgent(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli detect-agent --surface <id>\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .detectAgent(surfaceID: surface))
        if case let .agentInfo(info) = response, let info {
            print("\(info.kind.rawValue)\t\(info.executable)\t\(info.activity.rawValue)")
        }
    }

    static func handleInstallHooks(_ args: [String]) throws {
        let agent = args.dropFirst().first ?? flagValue(args, flag: "--agent") ?? ""
        AgentHookInstallerCLI.run(agentArg: agent)
    }

    /// `install-shell-integration [bash|zsh|fish|all]` — drop the OSC 133 script under the Harness
    /// home and wire a guarded `source` line into the shell's rc (idempotent, rc backed up). With
    /// no argument, install for the current `$SHELL`.
    static func handleInstallShellIntegration(_ args: [String]) {
        let arg = (args.dropFirst().first ?? "").lowercased()
        let shells: [ShellIntegration.Shell]
        switch arg {
        case "all":
            shells = ShellIntegration.Shell.allCases
        case "bash", "zsh", "fish":
            shells = [ShellIntegration.Shell(rawValue: arg)!]
        case "":
            guard let detected = ShellIntegration.Shell.detect(from: ProcessInfo.processInfo.environment["SHELL"] ?? "") else {
                fputs("install-shell-integration: couldn't detect your shell from $SHELL — pass one of: bash, zsh, fish, all\n", harnessStderr)
                exit(1)
            }
            shells = [detected]
        default:
            fputs("install-shell-integration: unknown shell \"\(arg)\" (expected bash, zsh, fish, or all)\n", harnessStderr)
            exit(1)
        }
        var failed = false
        for shell in shells {
            do {
                let r = try ShellIntegration.install(shell)
                if let backup = r.rcBackedUp { print("(backed up \(r.rcPath.lastPathComponent) to \(backup.path))") }
                if r.alreadyWired {
                    print("\(shell.rawValue): already wired in \(r.rcPath.path) — refreshed \(r.scriptPath.lastPathComponent)")
                } else {
                    print("\(shell.rawValue): wrote \(r.scriptPath.path) and added it to \(r.rcPath.path)")
                }
            } catch {
                fputs("install-shell-integration: \(shell.rawValue) failed: \(error)\n", harnessStderr)
                failed = true
            }
        }
        print("Restart your shell (or open a new Harness pane) to enable prompt marks, the success/failure gutter, and prompt jumping.")
        if failed { exit(1) }
    }

    static func handleAttach(_ args: [String]) throws -> Int32 {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli attach --surface <id> [--detach-keys <bytes>] [--host <name>]\n", harnessStderr)
            return 64
        }
        var configuration = AttachClient.Configuration()
        switch resolveDetachSequence(args) {
        case .parsed(let seq): configuration.detachSequence = seq
        case .absent: break  // flag absent — keep the default
        case .invalid(let message): fputs(message, harnessStderr); return 64
        }
        let endpoint = try resolveEndpoint(args)
        return try AttachClient.run(surfaceID: surface, configuration: configuration, endpoint: endpoint)
    }

    // MARK: - Remote daemons (over SSH)

    /// Build the daemon client for this invocation, honouring a global `--host <name>` flag that
    /// connects to a remote daemon through an SSH tunnel (configured via `harness-cli remote add`).
    static func makeClient(_ args: [String]) throws -> DaemonClient {
        DaemonClient(endpoint: try resolveEndpoint(args))
    }

    /// Resolve the endpoint for this invocation: the local socket, or — when `--host <name>` is
    /// given — the local end of an SSH tunnel to the named remote daemon.
    static func resolveEndpoint(_ args: [String]) throws -> Endpoint {
        guard let hostName = flagValue(args, flag: "--host") else { return .localControlSocket }
        guard let host = RemoteHostStore().host(named: hostName) else {
            fputs("harness-cli: unknown --host '\(hostName)'. Add it with `harness-cli remote add`.\n", harnessStderr)
            exit(64)
        }
        return try SSHTunnelManager.shared.endpoint(for: host)
    }

    /// `remote <list|add|remove>` — manage saved remote daemons reached over SSH.
    static func handleRemote(_ args: [String]) throws -> Int32 {
        let store = RemoteHostStore()
        let sub = args.count > 1 ? args[1] : "list"
        switch sub {
        case "list":
            let hosts = store.load()
            if hosts.isEmpty {
                print("No remote hosts. Add one with: harness-cli remote add --name <name> --ssh <user@host>")
            }
            for h in hosts {
                let live = SSHTunnelManager.shared.isConnected(h.name) ? " [connected]" : ""
                print("\(h.name)\t\(h.sshTarget)\t\(h.remoteSocketPath)\(live)")
            }
            return 0
        case "add":
            guard let name = flagValue(args, flag: "--name"), let ssh = flagValue(args, flag: "--ssh") else {
                fputs("Usage: harness-cli remote add --name <name> --ssh <user@host> "
                    + "--socket <remote-path> [--ssh-arg <arg> ...]\n", harnessStderr)
                return 64
            }
            guard let socketPath = flagValue(args, flag: "--socket") else {
                fputs("harness-cli remote add: could not infer the remote socket path; pass --socket "
                    + "<remote-path> (see `harness-cli doctor` on the remote for its value).\n", harnessStderr)
                return 64
            }
            var sshArgs: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == "--ssh-arg", i + 1 < args.count { sshArgs.append(args[i + 1]); i += 2 } else { i += 1 }
            }
            store.upsert(RemoteHost(name: name, sshTarget: ssh, remoteSocketPath: socketPath, sshArgs: sshArgs))
            print("Added remote '\(name)' -> \(ssh) (\(socketPath))")
            return 0
        case "remove":
            guard let name = flagValue(args, flag: "--name") else {
                fputs("Usage: harness-cli remote remove --name <name>\n", harnessStderr)
                return 64
            }
            store.remove(name: name)
            SSHTunnelManager.shared.stop(host: name)
            print("Removed remote '\(name)'")
            return 0
        default:
            fputs("Usage: harness-cli remote <list|add|remove> ...\n", harnessStderr)
            return 64
        }
    }


    /// `record --surface <id> --output <file> [--display]` — record a surface's
    /// output to a JSON Lines file (see `RecordingEvent`); `--display` also mirrors
    /// the output to this terminal. Stops on Ctrl-C or when the surface closes.
    static func handleRecord(_ args: [String], client: DaemonClient) -> Int32 {
        guard let surface = flagValue(args, flag: "--surface"),
              let output = flagValue(args, flag: "--output") else {
            fputs("Usage: harness-cli record --surface <uuid> --output <file> [--display]\n", harnessStderr)
            return 64
        }
        return RecordClient.run(
            client: client, surfaceID: surface, outputPath: output,
            display: args.contains("--display")
        )
    }

    /// `replay <file> [--speed <n>] [--no-timing]` — play a recording back to this
    /// terminal. `--speed` scales the recorded timing (2 = twice as fast),
    /// `--no-timing` dumps everything instantly. Ctrl-C stops cleanly.
    static func handleReplay(_ args: [String]) -> Int32 {
        guard let file = positionalArgs(args, skippingValuesFor: ["--speed"]).first else {
            fputs("Usage: harness-cli replay <file> [--speed <n>] [--no-timing]\n", harnessStderr)
            return 64
        }
        let speed = Double(flagValue(args, flag: "--speed") ?? "1") ?? .nan
        guard speed > 0 else {
            fputs("harness-cli replay: --speed must be a positive number\n", harnessStderr)
            return 64
        }
        return ReplayClient.run(path: file, speed: speed, honorTiming: !args.contains("--no-timing"))
    }

    #if canImport(HarnessTerminalKit)
    /// Renders a whole tab (split layout) into the terminal via the compositor.
    static func handleAttachWindow(_ args: [String]) throws -> Int32 {
        let selector: WindowAttachClient.TabSelector
        if let tabID = flagValue(args, flag: "--tab") ?? flagValue(args, flag: "--window") {
            selector = .id(tabID)
        } else if let session = flagValue(args, flag: "--session") {
            selector = .session(session)
        } else {
            selector = .active
        }
        var configuration = WindowAttachClient.Configuration()
        switch resolveDetachSequence(args) {
        case .parsed(let seq): configuration.detachSequence = seq
        case .absent: break  // flag absent — keep the default
        case .invalid(let message): fputs(message, harnessStderr); return 64
        }
        return try WindowAttachClient.run(tab: selector, configuration: configuration)
    }
    #endif

    /// Outcome of resolving the optional `--detach-keys` flag for the attach commands.
    ///   - `.absent` — flag not supplied; the caller keeps its built-in default.
    ///   - `.parsed(bytes)` — flag supplied and parsed.
    ///   - `.invalid(message)` — flag supplied but unparseable; the value would otherwise be
    ///     silently dropped, leaving the user attached with no way to detach. The message is a
    ///     ready-to-`fputs` line naming the bad value and the accepted formats.
    enum DetachKeys: Equatable {
        case absent
        case parsed([UInt8])
        case invalid(String)
    }

    static func resolveDetachSequence(_ args: [String]) -> DetachKeys {
        guard let raw = flagValue(args, flag: "--detach-keys") else {
            // A dangling `--detach-keys` (last token, no value) must not silently keep the default:
            // the user asked for a custom sequence and would otherwise get a different one.
            if flagIsDangling(args, flag: "--detach-keys") {
                return .invalid("harness-cli: --detach-keys requires a value "
                    + "('C-a d', '0x01 0x64', or comma-separated decimal bytes).\n")
            }
            return .absent
        }
        guard let parsed = parseDetachSequence(raw) else {
            return .invalid(
                "harness-cli: invalid --detach-keys '\(raw)'. "
                + "Use 'C-a d', '0x01 0x64', or comma-separated decimal bytes.\n")
        }
        return .parsed(parsed)
    }

    /// Parse `C-a d`, `0x01 0x64`, or comma-separated decimal bytes into a raw
    /// byte sequence. Single-character tokens become their literal ASCII byte.
    static func parseDetachSequence(_ raw: String) -> [UInt8]? {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        var bytes: [UInt8] = []
        for token in tokens {
            if token.hasPrefix("0x"), let value = UInt8(token.dropFirst(2), radix: 16) {
                bytes.append(value)
            } else if let value = UInt8(token) {
                bytes.append(value)
            } else if token.count == 3, token.hasPrefix("C-") || token.hasPrefix("c-") {
                guard let last = token.last,
                      let ch = last.uppercased().first,
                      let scalar = ch.asciiValue else { return nil }
                bytes.append(scalar & 0x1f)
            } else if token.count == 1, let scalar = token.first?.asciiValue {
                bytes.append(scalar)
            } else {
                return nil
            }
        }
        return bytes.isEmpty ? nil : bytes
    }

    static func printDaemonStats(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .daemonStats)
        guard case let .daemonStats(stats) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(stats, args) {
            print("pid: \(stats.pid)")
            print("version: \(stats.version ?? "?") (\(stats.build.map(String.init) ?? "pre-handshake"))")
            print(String(format: "uptime: %.0fs", stats.uptimeSeconds))
            print("surfaces: \(stats.surfaceCount)")
            print("scrollback: \(stats.totalScrollbackBytes) bytes")
            print("clients: \(stats.clientCount)")
            print("subscribers: \(stats.subscriberCount)")
            print("snapshot-revision: \(stats.snapshotRevision)")
        }
    }

    static func printClients(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .listClients)
        guard case let .clients(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                let attached = item.attachedSurfaceIDs.isEmpty ? "-" : item.attachedSurfaceIDs.joined(separator: ",")
                print("\(item.id.uuidString)\t\(item.label)\t\(attached)\t\(item.connectedAt)")
            }
        }
    }

    static func handleDetachClient(_ args: [String], client: DaemonClient) throws {
        guard let raw = flagValue(args, flag: "--client"), let id = UUID(uuidString: raw) else {
            fputs("Usage: harness-cli detach-client --client <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .detachClient(clientID: id))
    }

    static func handleBindKey(_ args: [String]) throws {
        // Usage: harness-cli bind-key [-T <table>] <spec> <command source>
        let table = flagValue(args, flag: "-T") ?? "prefix"
        // Drop the subcommand (`bind-key`/`bind`) at index 0; keep every other token so
        // the command source can itself contain flags (e.g. `new-window -h`).
        var positional = Array(args.dropFirst())
        positional.removeAll { $0 == "-T" }
        if let i = positional.firstIndex(of: table) { positional.remove(at: i) }
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
        let table = flagValue(args, flag: "-T") ?? "prefix"
        // Drop the subcommand (`unbind-key`/`unbind`) at index 0.
        var positional = Array(args.dropFirst())
        positional.removeAll { $0 == "-T" }
        if let i = positional.firstIndex(of: table) { positional.remove(at: i) }
        guard let spec = positional.first, let parsedSpec = KeySpec.parse(spec) else {
            fputs("Usage: harness-cli unbind-key [-T <table>] <spec>\n", harnessStderr)
            exit(1)
        }
        var set = KeybindingsStore.load()
        set.removeBinding(table: KeyTableID(rawValue: table), spec: parsedSpec)
        let url = try KeybindingsStore.save(set)
        print(url.path)
    }

    static func handleSetBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        let data: Data
        if let inline = flagValue(args, flag: "--data") {
            data = Data(inline.utf8)
        } else if args.contains("--stdin") {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            fputs("Usage: harness-cli set-buffer (--data <text> | --stdin) [--name <name>]\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .setBuffer(name: name, data: data))
        if case let .text(final) = response { print(final) }
    }

    static func handleListBuffers(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .listBuffers)
        guard case let .buffers(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                print("\(item.name)\t\(item.byteCount)B\t\(item.preview)")
            }
        }
    }

    static func handleShowBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        let response = try checkedRequest(client, .getBuffer(name: name))
        guard case let .buffer(summary) = response, let data = summary.data else {
            throw DaemonClientError.unexpectedResponse
        }
        FileHandle.standardOutput.write(data)
    }

    static func handleDeleteBuffer(_ args: [String], client: DaemonClient) throws {
        guard let name = flagValue(args, flag: "--name") else {
            fputs("Usage: harness-cli delete-buffer --name <name>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .deleteBuffer(name: name))
    }

    static func handlePasteBuffer(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli paste-buffer --surface <id> [--name <name>] [-p|--bracketed]\n", harnessStderr)
            exit(1)
        }
        let name = flagValue(args, flag: "--name")
        let bracketed = args.contains("-p") || args.contains("--bracketed")
        _ = try checkedRequest(client, .pasteBuffer(surfaceID: surface, name: name, bracketed: bracketed))
    }

    /// Positional (non-flag) arguments, skipping the subcommand at index 0 and the
    /// value tokens that follow the given value-taking flags.
    static func positionalArgs(_ args: [String], skippingValuesFor flags: Set<String>) -> [String] {
        var out: [String] = []
        var i = 1  // index 0 is the subcommand
        while i < args.count {
            let a = args[i]
            if flags.contains(a) { i += 2; continue }   // flag + its value
            if a.hasPrefix("-") { i += 1; continue }
            out.append(a); i += 1
        }
        return out
    }

    /// `save-buffer [--name <name>] <path>` — write a paste buffer to a file (file
    /// I/O is client-side; the buffer data comes over IPC).
    static func handleSaveBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        guard let path = flagValue(args, flag: "--file") ?? positionalArgs(args, skippingValuesFor: ["--name", "--file"]).first else {
            fputs("Usage: harness-cli save-buffer [--name <name>] <path>\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .getBuffer(name: name))
        guard case let .buffer(summary) = response, let data = summary.data else {
            throw DaemonClientError.unexpectedResponse
        }
        let expanded = (path as NSString).expandingTildeInPath
        try data.write(to: URL(fileURLWithPath: expanded))
    }

    /// `load-buffer [--name <name>] <path>` — read a file into a new paste buffer.
    static func handleLoadBuffer(_ args: [String], client: DaemonClient) throws {
        let name = flagValue(args, flag: "--name")
        guard let path = flagValue(args, flag: "--file") ?? positionalArgs(args, skippingValuesFor: ["--name", "--file"]).first else {
            fputs("Usage: harness-cli load-buffer [--name <name>] <path>\n", harnessStderr)
            exit(1)
        }
        let expanded = (path as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        let response = try checkedRequest(client, .setBuffer(name: name, data: data))
        if case let .text(final) = response { print(final) }
    }

    static func handleSelectLayout(_ args: [String], client: DaemonClient) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr),
              let layout = flagValue(args, flag: "--layout")
        else {
            fputs("Usage: harness-cli select-layout --tab <uuid> --layout <name> [--main <paneUUID>]\n", harnessStderr)
            exit(1)
        }
        let mainPaneID: UUID?
        switch optionalUUIDFlag(args, flag: "--main") {
        case .absent: mainPaneID = nil
        case .valid(let id): mainPaneID = id
        case .invalid(let raw):
            fputs("select-layout: --main must be a pane UUID (got '\(raw)')\n", harnessStderr)
            exit(1)
        case .dangling:
            fputs("select-layout: --main requires a value\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .applyLayout(tabID: tabID, layout: layout, mainPaneID: mainPaneID))
    }

    static func handleCycleLayout(_ args: [String], client: DaemonClient, forward: Bool) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr) else {
            fputs("Usage: harness-cli \(forward ? "next" : "previous")-layout --tab <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, forward ? .nextLayout(tabID: tabID) : .previousLayout(tabID: tabID))
    }

    static func handleRotateWindow(_ args: [String], client: DaemonClient) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr) else {
            fputs("Usage: harness-cli rotate-window --tab <uuid> [--reverse]\n", harnessStderr)
            exit(1)
        }
        let forward = !args.contains("--reverse")
        _ = try checkedRequest(client, .rotatePanes(tabID: tabID, forward: forward))
    }

    static func handleBreakPane(_ args: [String], client: DaemonClient) throws {
        guard let paneStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneStr) else {
            fputs("Usage: harness-cli break-pane --pane <uuid>\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .breakPane(paneID: paneID))
        if case let .tabID(id) = response { print(id.uuidString) }
    }

    static func handleJoinPane(_ args: [String], client: DaemonClient) throws {
        guard let srcStr = flagValue(args, flag: "--src"), let src = UUID(uuidString: srcStr),
              let dstStr = flagValue(args, flag: "--dst"), let dst = UUID(uuidString: dstStr),
              let dirStr = flagValue(args, flag: "--direction"),
              let direction = SplitDirection(rawValue: dirStr)
        else {
            fputs("Usage: harness-cli join-pane --src <uuid> --dst <uuid> --direction horizontal|vertical\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .joinPane(sourcePaneID: src, destPaneID: dst, direction: direction))
        if case let .paneID(id) = response { print(id.uuidString) }
    }

    /// `move-pane --src <uuid> --dst <uuid> [--direction horizontal|vertical]` —
    /// identical daemon op to join-pane, with an explicit source (tmux's move-pane).
    static func handleMovePane(_ args: [String], client: DaemonClient) throws {
        guard let srcStr = flagValue(args, flag: "--src"), let src = UUID(uuidString: srcStr),
              let dstStr = flagValue(args, flag: "--dst"), let dst = UUID(uuidString: dstStr)
        else {
            fputs("Usage: harness-cli move-pane --src <uuid> --dst <uuid> [--direction horizontal|vertical]\n", harnessStderr)
            exit(1)
        }
        // Absent --direction defaults to horizontal (tmux move-pane); a provided-but-invalid
        // value is an error, never a silent horizontal move (join-pane validates the same way).
        let direction: SplitDirection
        if let dirStr = flagValue(args, flag: "--direction") {
            guard let parsed = SplitDirection(rawValue: dirStr) else {
                fputs("move-pane: --direction must be horizontal|vertical (got '\(dirStr)')\n", harnessStderr)
                exit(1)
            }
            direction = parsed
        } else {
            direction = .horizontal
        }
        let response = try checkedRequest(client, .joinPane(sourcePaneID: src, destPaneID: dst, direction: direction))
        if case let .paneID(id) = response { print(id.uuidString) }
    }

    /// `renumber-windows --session <uuid>` — renumber a session's tab indices.
    static func handleRenumberWindows(_ args: [String], client: DaemonClient) throws {
        guard let sessionStr = flagValue(args, flag: "--session"), let session = UUID(uuidString: sessionStr) else {
            fputs("Usage: harness-cli renumber-windows --session <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renumberWindows(sessionID: session))
    }

    static func handleRespawnPane(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli respawn-pane --surface <id> [--clear-history|-k]\n", harnessStderr)
            exit(1)
        }
        let keepHistory = !(args.contains("--clear-history") || args.contains("-k"))
        _ = try checkedRequest(client, .respawnPane(surfaceID: surface, keepHistory: keepHistory))
    }

    static func handleSelectPane(_ args: [String], client: DaemonClient) throws {
        guard let paneStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneStr) else {
            fputs("Usage: harness-cli select-pane --pane <uuid> --dir L|R|U|D\n", harnessStderr)
            exit(1)
        }
        guard let dirStr = flagValue(args, flag: "--dir")?.lowercased(),
              let axis = DirectionalAxis(short: dirStr)
        else {
            fputs("Usage: harness-cli select-pane --pane <uuid> --dir L|R|U|D\n", harnessStderr)
            exit(1)
        }
        let response = try checkedRequest(client, .selectPaneDirectional(currentPaneID: paneID, direction: axis))
        if case let .paneID(id) = response { print(id.uuidString) }
    }

    static func handleSetOption(_ args: [String], client: DaemonClient) throws {
        // Usage: set-option [-g|-w|-s|-t|-p] [-T <target>] <key> <value>
        var scope = "global"
        if args.contains("-g") { scope = "global" }
        if args.contains("-w") { scope = "workspace" }
        if args.contains("-s") { scope = "session" }
        if args.contains("-t") { scope = "tab" }
        if args.contains("-p") { scope = "pane" }
        let target = flagValue(args, flag: "-T")
        // Scoped options resolve by exact target — a nil-target workspace/session/tab/pane
        // entry is stored but unreachable by every read path (the fallback chain only widens
        // toward global). Require the target instead of silently writing a dead option.
        if scope != "global", target == nil {
            fputs("set-option: \(scope) scope requires -T <target>\n", harnessStderr)
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
    private static func requireSessionID(_ nameOrID: String, client: DaemonClient, command: String) throws -> SessionID {
        if let session = resolveSession(try snapshot(client), nameOrID: nameOrID) { return session.id }
        fputs("\(command): no session matches '\(nameOrID)'\n", harnessStderr)
        exit(1)
    }

    static func handleSetEnvironment(_ args: [String], client: DaemonClient) throws {
        // Usage: set-environment [-g] [-u] [-s <session name|uuid>] <key> [value]
        // -g = global (default when no -s); -u = unset; -s targets a session.
        let global = args.contains("-g")
        let unset = args.contains("-u")
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
        let format = args.dropFirst().joined(separator: " ")
        guard !format.isEmpty else {
            fputs("Usage: harness-cli display-message <format>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .displayMessage(format: format))
    }

    static func handleListKeys(_ args: [String]) throws {
        let tableFlag = flagValue(args, flag: "-T")
        let set = KeybindingsStore.load()
        let chosen: [KeyTable] = tableFlag.map {
            [set.table(KeyTableID(rawValue: $0))].compactMap { $0 }
        } ?? set.tableList
        for table in chosen {
            print("[\(table.id.rawValue)]")
            for binding in table.bindings {
                let note = binding.note.map { "  -- \($0)" } ?? ""
                print("  \(binding.spec.description)\t\(binding.command.shortDescription)\(note)")
            }
        }
    }

    static func installCLI() throws {
        let source = CLIInstallLocator.sourceBinary()
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw DaemonSessionError.daemonError("harness-cli binary not found at \(source.path)")
        }
        let dest = HarnessPaths.applicationSupport.appendingPathComponent("bin/harness-cli")
        try HarnessPaths.ensureDirectories()
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyExecutable(source: source, destination: dest)
        print(dest.path)
        print("export PATH=\"\(dest.deletingLastPathComponent().path):$PATH\"")
        // Install the daemon as a managed service so it survives reboot/logout: launchd on macOS,
        // systemd --user on Linux. The same flow works on a headless box.
        let installer = ServiceInstallers.current
        if let daemon = locateDaemonBinary() {
            do {
                let installedDaemon = HarnessPaths.applicationSupport.appendingPathComponent("bin/HarnessDaemon")
                try copyExecutable(source: daemon, destination: installedDaemon)
                print("daemon: \(installedDaemon.path)")
                let report = try installer.install(daemonPath: installedDaemon, harnessHome: HarnessPaths.applicationSupport)
                print("service (\(installer.backendName)): \(report.unitPath.path)")
            } catch {
                fputs("warning: \(installer.backendName) install failed: \(error)\n", harnessStderr)
            }
        } else {
            fputs("warning: HarnessDaemon binary not found; service not installed\n", harnessStderr)
        }
        // Shell completions for the user's login shell, so they work out of the box: fish drops
        // into its auto-load dir; zsh/bash get a guarded, backed-up, idempotent `source` block
        // wired into the rc (the same mechanism as install-shell-integration). Any shell can also
        // regenerate the script on demand with `harness-cli completions <shell>`.
        do {
            for line in try ShellCompletionInstaller.installForLoginShell() { print(line) }
        } catch {
            fputs("warning: shell completion install failed: \(error)\n", harnessStderr)
        }
        print("Tip: run 'harness-cli install-shell-integration' to enable OSC 133 prompt marks, "
            + "the success/failure gutter, and prompt jumping.")
    }

    static func copyExecutable(source: URL, destination: URL) throws {
        try BinaryRefresher.copyExecutable(from: source, to: destination)
    }

    /// Locate the daemon executable: next to the running CLI (the app bundle, or `.build/<config>/`
    /// in dev, or a Linux install dir), the previously-installed copy under the Harness home, or the
    /// macOS app bundle. An explicit `HARNESS_DAEMON_PATH` always wins.
    static func locateDaemonBinary() -> URL? {
        if let override = ProcessInfo.processInfo.environment["HARNESS_DAEMON_PATH"],
           !override.isEmpty, FileManager.default.fileExists(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let cli = CLIInstallLocator.sourceBinary()
        let candidate = cli.deletingLastPathComponent().appendingPathComponent("HarnessDaemon")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        // The copy `install` placed under the Harness home.
        let installed = HarnessPaths.applicationSupport.appendingPathComponent("bin/HarnessDaemon")
        if FileManager.default.fileExists(atPath: installed.path) { return installed }
        // The installed macOS app bundle (no-op on Linux).
        let appCandidate = URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/HarnessDaemon")
        if FileManager.default.fileExists(atPath: appCandidate.path) { return appCandidate }
        return nil
    }

    /// `harness daemon` — run HarnessDaemon in the foreground (replacing this process), for
    /// `systemd Type=simple`, container entrypoints, and debugging. Stdio/signals pass straight
    /// through to the daemon.
    static func runDaemonForeground() -> Never {
        guard let daemon = locateDaemonBinary() else {
            fputs("harness-cli daemon: HarnessDaemon binary not found "
                + "(set HARNESS_DAEMON_PATH or run `harness-cli install`).\n", harnessStderr)
            exit(1)
        }
        let path = daemon.path
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { argv.forEach { $0.map { free($0) } } } // unreachable on success (execv replaces us)
        execv(path, &argv)
        fputs("harness-cli daemon: exec failed for \(path)\n", harnessStderr)
        exit(1)
    }

    static func flagValue(_ args: [String], flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// True when `flag` is present in `args` but has no following value (it is the last token).
    /// `flagValue` collapses this with "absent" by returning nil for both — so a truncated script
    /// arg like `new-split --tab X --pane` would silently target the active pane (#92's class).
    /// Callers that could act on a wrong target must error loudly on dangling instead of falling
    /// back. (A flag whose "value" is itself another `--flag` is treated as a real, if bogus,
    /// value and rejected downstream by the type check — only a missing trailing token is dangling.)
    static func flagIsDangling(_ args: [String], flag: String) -> Bool {
        guard let index = args.firstIndex(of: flag) else { return false }
        return index + 1 >= args.count
    }

    /// Outcome of resolving an optional UUID-valued flag without collapsing "absent" and "invalid"
    /// into the same nil — the silent-fallback class fixed elsewhere (list-panes/kill-pane, #68).
    enum OptionalUUID: Equatable {
        case absent              // flag not supplied; caller keeps its default (e.g. active pane)
        case valid(UUID)         // flag supplied and a well-formed UUID
        case invalid(String)     // flag supplied but not a UUID; caller should error loudly
        case dangling            // flag supplied as the last token with no value; error loudly
    }

    static func optionalUUIDFlag(_ args: [String], flag: String) -> OptionalUUID {
        guard let raw = flagValue(args, flag: flag) else {
            // nil means either absent or present-but-dangling; only the latter is an error.
            return flagIsDangling(args, flag: flag) ? .dangling : .absent
        }
        guard let id = UUID(uuidString: raw) else { return .invalid(raw) }
        return .valid(id)
    }

    static func checkedRequest(_ client: DaemonClient, _ request: IPCRequest, timeout: TimeInterval = 2) throws -> IPCResponse {
        let response = try client.request(request, timeout: timeout)
        if case let .error(message) = response {
            throw DaemonSessionError.daemonError(message)
        }
        return response
    }

    /// Shared output branch for list/show commands: emit `payload` as JSON when `--json` is
    /// present (compact, or indented with `--pretty`), otherwise run the text closure. Keeps the
    /// JSON-vs-text decision in one place so each handler stays a couple of lines.
    static func emit<T: Encodable>(_ payload: T, _ args: [String], text: () -> Void) throws {
        if args.contains("--json") {
            print(try JSONOutputFormatter.encode(payload, pretty: args.contains("--pretty")))
        } else {
            text()
        }
    }

    /// `doctor [--json] [--pretty]` — diagnose the daemon, control socket, paths, and integrations.
    /// Exits nonzero only on a clear failure (a misconfiguration or security issue); warnings
    /// (daemon not running, optional integrations absent) keep exit 0.
    static func runDoctor(_ args: [String], client: DaemonClient) throws {
        var daemonReachable = false
        if let response = try? client.request(.ping, timeout: 0.3), case .pong = response {
            daemonReachable = true
        }
        var stats: DaemonStats?
        if daemonReachable,
           let response = try? client.request(.daemonStats, timeout: 0.3),
           case let .daemonStats(s) = response {
            stats = s
        }
        let report = DoctorRunner.run(daemonReachable: daemonReachable, cliPath: resolvedCLIPath(), daemonStats: stats)
        if args.contains("--json") {
            print(try JSONOutputFormatter.encode(report, pretty: args.contains("--pretty")))
        } else {
            report.text().forEach { print($0) }
        }
        exit(report.exitCode)
    }

    /// `completions <zsh|fish|bash>` — print the static completion script for `shell` to stdout.
    static func printCompletions(_ args: [String]) throws {
        let positional = Array(args.dropFirst()).first { !$0.hasPrefix("-") }
        guard let raw = positional, let shell = ShellIntegration.Shell(rawValue: raw) else {
            fputs("Usage: harness-cli completions <zsh|fish|bash>\n", harnessStderr)
            exit(1)
        }
        print(CompletionGenerator.script(for: shell))
    }

    /// The running executable's path for `doctor` to report (the real binary, not `$0`'s spelling).
    static func resolvedCLIPath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "harness-cli"
    }

    /// `version [--json]` — print this CLI's version/build and, best-effort, the running daemon's
    /// (from the `daemonStats` handshake). A build mismatch is the stale-daemon signature (#60).
    static func printVersion(_ args: [String]) {
        struct VersionReport: Encodable {
            var cliVersion: String
            var cliBuild: Int
            var daemonVersion: String?
            var daemonBuild: Int?
            var daemonRunning: Bool
        }
        var report = VersionReport(
            cliVersion: HarnessVersion.short,
            cliBuild: HarnessVersion.build,
            daemonVersion: nil,
            daemonBuild: nil,
            daemonRunning: false
        )
        if let client = try? makeClient(args),
           let response = try? client.request(.daemonStats, timeout: 0.3),
           case let .daemonStats(stats) = response {
            report.daemonRunning = true
            report.daemonVersion = stats.version
            report.daemonBuild = stats.build
        }
        if args.contains("--json") {
            if let encoded = try? JSONOutputFormatter.encode(report, pretty: args.contains("--pretty")) {
                print(encoded)
            }
            return
        }
        print("harness-cli \(report.cliVersion) (\(report.cliBuild))")
        if !report.daemonRunning {
            print("daemon: not running")
        } else if let build = report.daemonBuild {
            var line = "daemon: \(report.daemonVersion ?? "?") (\(build))"
            if build != HarnessVersion.build { line += "  [mismatch — restart Harness.app, or run: harness-cli install]" }
            print(line)
        } else {
            print("daemon: running, pre-handshake build (no version reported)")
        }
    }

    static func printUsage() {
        print("""
        harness-cli — control Harness terminal sessions

        List/show commands accept [--json] [--pretty] (compact JSON by default; --pretty indents).

        Commands:
          doctor [--json]                             (diagnose daemon, socket, paths, integrations)
          version [--json]                            (print CLI and daemon versions; flags build mismatch)
          color-check                                  (print ANSI/256/truecolor diagnostic swatches)
          theme-preview [--theme <name>] [--all]       (print deterministic themed sample output)
          completions <zsh|fish|bash>                 (print a shell completion script to stdout)
          list-workspaces [--json] [--pretty]
          list-surfaces [--json] [--pretty]
          list-sessions [--json] [--pretty]
          list-windows [--session <name|uuid>] [--json] [--pretty]
          list-panes [--tab <uuid>] [--json] [--pretty]
          list-agents [--waiting] [--json] [--pretty] (running agents: state, age, surface)
          has-session --session <name|uuid>           (exit 0 if it exists, else 1)
          list-commands
          get-snapshot
          new-workspace --name <name>
          new-session --workspace <name|uuid> [--cwd path] [--name name]
          new-tab --workspace <name|uuid> [--cwd path]
          new-split --tab <uuid> --direction horizontal|vertical [--pane <uuid>]
          select-workspace --workspace <name|uuid>
          select-session --workspace <name|uuid> --session <uuid>
          select-tab --workspace <uuid> --tab <uuid>
          close-tab --tab <uuid>
          close-session --session <uuid>
          promote-session --session <uuid>            (pin: survive a clean quit in Plain mode)
          demote-session --session <uuid>             (unpin: ephemeral again)
          send --surface <uuid> --text "..."
          send-keys --surface <uuid> --keys "C-c Up Enter ..."
          capture-pane --surface <uuid> [--scrollback]
          kill-pane --pane <uuid>
          capture-pane --surface <uuid> [--scrollback] [-S <start>] [-E <end>] [-p]
          pipe-pane --surface <uuid> [<shell-command>]   (omit to stop)
          link-window --tab <uuid> --target-session <uuid>
          unlink-window --tab <uuid>
          control-mode | -CC                             (tmux control protocol over stdio)
          swap-pane --src <uuid> --dst <uuid>
          resize-pane --pane <uuid> --dir L|R|U|D [--amount N]
          zoom-pane --pane <uuid>
          copy-mode --surface <uuid> [--enter|--exit]
          rename-tab --tab <uuid> --name "..."
          rename-session --session <uuid> --name "..."
          rename-workspace --id <uuid> --name "..."
          detect-agent --surface <uuid>
          install-hooks <codex|claude-code|cursor|grok|opencode|pi|hermes|openclaw>
          install-shell-integration [bash|zsh|fish|all]  (OSC 133 prompt marks + gutter)
          attach --surface <uuid> [--detach-keys "C-a d"]
          record --surface <uuid> --output <file> [--display]
          replay <file> [--speed <n>] [--no-timing]
          notify --surface <uuid> [--title t] [--body b] [--from-hook]
          daemon-stats [--json] [--pretty]
          list-clients [--json] [--pretty]
          detach-client --client <uuid>
          bind-key [-T <table>] <spec> <command...>
          unbind-key [-T <table>] <spec>
          list-keys [-T <table>]
          set-buffer (--data <text> | --stdin) [--name <name>]
          list-buffers [--json] [--pretty]
          show-buffer [--name <name>]
          delete-buffer --name <name>
          paste-buffer --surface <uuid> [--name <name>]
          select-layout --tab <uuid> --layout even-horizontal|even-vertical|main-horizontal|main-vertical|tiled
          next-layout --tab <uuid>
          previous-layout --tab <uuid>
          rotate-window --tab <uuid> [--reverse]
          break-pane --pane <uuid>
          join-pane --src <uuid> --dst <uuid> --direction horizontal|vertical
          respawn-pane --surface <id> [--clear-history|-k]
          select-pane --pane <uuid> --dir L|R|U|D
          set-option [-g|-w|-s|-t|-p] [-T target] <key> <value>
          show-options [-g|-w|-s|-t|-p] [--json] [--pretty]
          set-environment [-g] [-u] [-s <sessionID>] <key> [value]
          show-environment [-g] [-s <sessionID>] [--json] [--pretty]
          bind-hook <event> <command...> [--if <format>]
          unbind-hook --id <uuid>
          list-hooks [--event <event>] [--json] [--pretty]
          display-message <format>
          install
          ping
        """)
    }
}

enum CLIInstallLocator {
    static func sourceBinary() -> URL {
        if let exe = Bundle.main.executableURL {
            return exe
        }
        return URL(fileURLWithPath: CommandLine.arguments[0])
    }
}
