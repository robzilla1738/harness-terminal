#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore
import HarnessTerminalEngine
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
            case "kill-server":
                handleKillServer(args)
            case "start-server":
                handleStartServer(args, client: client)
            case "show-messages":
                if case let .text(log) = try checkedRequest(client, .showMessages) {
                    print(log.isEmpty ? "no messages" : log)
                }
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
            case "clear-history", "clearhist":
                try handleClearHistory(args, client: client)
            case "select-pane":
                try handleSelectPane(args, client: client)
            case "set-option":
                try handleSetOption(args, defaultScope: "global", client: client)
            case "setw", "set-window-option":
                // tmux `setw` is a WINDOW option — same default the bindable parser
                // uses, so a sourced `.tmux.conf` line and the CLI write the same scope.
                try handleSetOption(args, defaultScope: "tab", client: client)
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

    // MARK: - Remote daemons (over SSH)


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

}

enum CLIInstallLocator {
}
