import Foundation
import HarnessCore

@main
struct HarnessCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }
        let client = DaemonClient()
        do {
            switch command {
            case "list-workspaces":
                try printWorkspaces(client)
            case "list-surfaces":
                try printSurfaces(client)
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
                    fputs("Usage: harness-cli close-tab --tab <uuid>\n", stderr)
                    exit(1)
                }
                _ = try checkedRequest(client, .closeTab(tabID: tabID))
            case "close-session":
                guard let sessionID = UUID(uuidString: flagValue(args, flag: "--session") ?? "") else {
                    fputs("Usage: harness-cli close-session --session <uuid>\n", stderr)
                    exit(1)
                }
                _ = try checkedRequest(client, .closeSession(sessionID: sessionID))
            case "send":
                guard let surface = flagValue(args, flag: "--surface"),
                      let text = flagValue(args, flag: "--text")
                else {
                    fputs("Usage: harness-cli send --surface <uuid> --text \"...\"\n", stderr)
                    exit(1)
                }
                _ = try checkedRequest(client, .send(surfaceID: surface, text: text))
            case "notify":
                guard let surface = flagValue(args, flag: "--surface") else {
                    fputs("Usage: harness-cli notify --surface <uuid> [--title t] [--body b]\n", stderr)
                    exit(1)
                }
                let title = flagValue(args, flag: "--title") ?? "Agent"
                let body = flagValue(args, flag: "--body") ?? flagValue(args, flag: "--message") ?? "Needs attention"
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
            case "attach":
                let code = try handleAttach(args)
                exit(code)
            case "attach-window":
                let code = try handleAttachWindow(args)
                exit(code)
            case "daemon-stats":
                try printDaemonStats(client)
            case "list-clients":
                try printClients(client)
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
                try handleListBuffers(client)
            case "show-buffer":
                try handleShowBuffer(args, client: client)
            case "delete-buffer":
                try handleDeleteBuffer(args, client: client)
            case "paste-buffer":
                try handlePasteBuffer(args, client: client)
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
            fputs("harness-cli: \(error)\n", stderr)
            exit(1)
        }
    }

    static func handleNewTab(_ args: [String], client: DaemonClient) throws {
        if let name = flagValue(args, flag: "--workspace") {
            let cwd = flagValue(args, flag: "--cwd")
            let response = try checkedRequest(client, .newTabInWorkspace(named: name, cwd: cwd))
            if case let .tabID(id) = response { print(id.uuidString) }
            return
        }
        guard let workspaceID = UUID(uuidString: flagValue(args, flag: "--workspace-id") ?? "") else {
            fputs("Usage: harness-cli new-tab --workspace <name|uuid> [--cwd path]\n", stderr)
            exit(1)
        }
        let cwd = flagValue(args, flag: "--cwd")
        let response = try checkedRequest(client, .newTab(workspaceID: workspaceID, cwd: cwd))
        if case let .tabID(id) = response { print(id.uuidString) }
    }

    static func handleNewSession(_ args: [String], client: DaemonClient) throws {
        guard let workspaceID = try resolveWorkspaceID(args, client: client) else {
            fputs("Usage: harness-cli new-session --workspace <name|uuid> [--cwd path] [--name name]\n", stderr)
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
            fputs("Usage: harness-cli new-split --tab <uuid> --direction horizontal|vertical\n", stderr)
            exit(1)
        }
        let paneID = UUID(uuidString: flagValue(args, flag: "--pane") ?? "")
        let response = try checkedRequest(client, .newSplit(tabID: tabID, paneID: paneID, direction: direction))
        if case let .paneID(id) = response { print(id.uuidString) }
    }

    static func handleSelectWorkspace(_ args: [String], client: DaemonClient) throws {
        guard let target = flagValue(args, flag: "--workspace") ?? flagValue(args, flag: "--id") else {
            fputs("Usage: harness-cli select-workspace --workspace <name|uuid>\n", stderr)
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
            fputs("Usage: harness-cli select-tab --workspace <uuid> --tab <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .selectTab(workspaceID: workspaceID, tabID: tabID))
    }

    static func handleSelectSession(_ args: [String], client: DaemonClient) throws {
        guard let workspaceID = try resolveWorkspaceID(args, client: client),
              let sessionID = UUID(uuidString: flagValue(args, flag: "--session") ?? "")
        else {
            fputs("Usage: harness-cli select-session --workspace <name|uuid> --session <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .selectSession(workspaceID: workspaceID, sessionID: sessionID))
    }

    static func printWorkspaces(_ client: DaemonClient) throws {
        let response = try checkedRequest(client, .listWorkspaces)
        guard case let .workspaces(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            print("\(item.id)\t\(item.name)\t\(item.tabCount) sessions")
        }
    }

    static func printSurfaces(_ client: DaemonClient) throws {
        let response = try checkedRequest(client, .listSurfaces)
        guard case let .surfaces(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            print("\(item.surfaceID)\t\(item.workspaceName)\t\(item.tabTitle)\t\(item.cwd)")
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
            fputs("Usage: harness-cli send-keys --surface <id> --keys \"C-c Up Enter ...\"\n", stderr)
            exit(1)
        }
        let tokens = keys.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        _ = try checkedRequest(client, .sendKeys(surfaceID: surface, keys: tokens))
    }

    static func handleCapturePane(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli capture-pane --surface <id> [--scrollback] [-S <start>] [-E <end>] [-p]\n", stderr)
            exit(1)
        }
        // -S/-E request an ANSI-stripped line range (tmux `-p` prints to stdout,
        // which is the default here). Negative numbers count back from the bottom.
        let start = flagValue(args, flag: "-S").flatMap(Int.init)
        let end = flagValue(args, flag: "-E").flatMap(Int.init)
        let response: IPCResponse
        if args.contains("-S") || args.contains("-E") {
            response = try checkedRequest(client, .capturePaneRange(surfaceID: surface, start: start, end: end))
        } else {
            response = try checkedRequest(client, .capturePane(surfaceID: surface, includeScrollback: args.contains("--scrollback")))
        }
        if case let .text(text) = response { print(text) }
    }

    static func handlePipePane(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli pipe-pane --surface <id> [<shell-command>]   (omit command to stop)\n", stderr)
            exit(1)
        }
        let command = args.first { !$0.hasPrefix("-") && $0 != surface }
        _ = try checkedRequest(client, .pipePane(surfaceID: surface, shellCommand: command))
    }

    static func handleLinkWindow(_ args: [String], client: DaemonClient) throws {
        guard let tabRaw = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabRaw),
              let sessionRaw = flagValue(args, flag: "--target-session"), let sessionID = UUID(uuidString: sessionRaw) else {
            fputs("Usage: harness-cli link-window --tab <uuid> --target-session <uuid>\n", stderr)
            exit(1)
        }
        let response = try checkedRequest(client, .linkWindow(tabID: tabID, targetSessionID: sessionID))
        if case let .tabID(id) = response { print(id.uuidString) }
    }

    static func handleUnlinkWindow(_ args: [String], client: DaemonClient) throws {
        guard let tabRaw = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabRaw) else {
            fputs("Usage: harness-cli unlink-window --tab <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .unlinkWindow(tabID: tabID))
    }

    static func handlePaneCommand(_ args: [String], client: DaemonClient, _ make: (UUID) -> IPCRequest) throws {
        guard let paneIDStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneIDStr) else {
            fputs("Missing or invalid --pane <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, make(paneID))
    }

    static func handleSwapPane(_ args: [String], client: DaemonClient) throws {
        guard let srcStr = flagValue(args, flag: "--src"), let src = UUID(uuidString: srcStr),
              let dstStr = flagValue(args, flag: "--dst"), let dst = UUID(uuidString: dstStr)
        else {
            fputs("Usage: harness-cli swap-pane --src <uuid> --dst <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .swapPanes(srcPaneID: src, dstPaneID: dst))
    }

    static func handleResizePane(_ args: [String], client: DaemonClient) throws {
        guard let paneStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneStr),
              let dirStr = flagValue(args, flag: "--dir")?.lowercased(),
              let direction = parseDirection(dirStr)
        else {
            fputs("Usage: harness-cli resize-pane --pane <uuid> --dir L|R|U|D [--amount N]\n", stderr)
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
            fputs("Usage: harness-cli copy-mode --surface <id> [--enter|--exit]\n", stderr)
            exit(1)
        }
        let enabled = !args.contains("--exit")
        _ = try checkedRequest(client, .setCopyMode(surfaceID: surface, enabled: enabled))
    }

    static func handleRenameTab(_ args: [String], client: DaemonClient) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-tab --tab <uuid> --name \"...\"\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renameTab(tabID: tabID, name: name))
    }

    static func handleRenameSession(_ args: [String], client: DaemonClient) throws {
        guard let sessionStr = flagValue(args, flag: "--session"), let sessionID = UUID(uuidString: sessionStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-session --session <uuid> --name \"...\"\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renameSession(sessionID: sessionID, name: name))
    }

    static func handleRenameWorkspace(_ args: [String], client: DaemonClient) throws {
        guard let idStr = flagValue(args, flag: "--id") ?? flagValue(args, flag: "--workspace"),
              let id = UUID(uuidString: idStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-workspace --id <uuid> --name \"...\"\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renameWorkspace(workspaceID: id, name: name))
    }

    static func handleDetectAgent(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli detect-agent --surface <id>\n", stderr)
            exit(1)
        }
        let response = try checkedRequest(client, .detectAgent(surfaceID: surface))
        if case let .agentInfo(info) = response, let info {
            print("\(info.kind.rawValue)\t\(info.executable)\t\(info.activity.rawValue)")
        }
    }

    static func handleInstallHooks(_ args: [String]) throws {
        let agent = args.dropFirst().first ?? flagValue(args, flag: "--agent") ?? ""
        try AgentHookInstaller.install(agent: agent)
    }

    static func handleAttach(_ args: [String]) throws -> Int32 {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli attach --surface <id> [--detach-keys <bytes>]\n", stderr)
            return 64
        }
        var configuration = AttachClient.Configuration()
        if let raw = flagValue(args, flag: "--detach-keys"),
           let parsed = parseDetachSequence(raw) {
            configuration.detachSequence = parsed
        }
        return try AttachClient.run(surfaceID: surface, configuration: configuration)
    }

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
        if let raw = flagValue(args, flag: "--detach-keys"),
           let parsed = parseDetachSequence(raw) {
            configuration.detachSequence = parsed
        }
        return try WindowAttachClient.run(tab: selector, configuration: configuration)
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

    static func printDaemonStats(_ client: DaemonClient) throws {
        let response = try checkedRequest(client, .daemonStats)
        guard case let .daemonStats(stats) = response else { throw DaemonClientError.unexpectedResponse }
        print("pid: \(stats.pid)")
        print(String(format: "uptime: %.0fs", stats.uptimeSeconds))
        print("surfaces: \(stats.surfaceCount)")
        print("scrollback: \(stats.totalScrollbackBytes) bytes")
        print("clients: \(stats.clientCount)")
        print("subscribers: \(stats.subscriberCount)")
        print("snapshot-revision: \(stats.snapshotRevision)")
    }

    static func printClients(_ client: DaemonClient) throws {
        let response = try checkedRequest(client, .listClients)
        guard case let .clients(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            let attached = item.attachedSurfaceIDs.isEmpty ? "-" : item.attachedSurfaceIDs.joined(separator: ",")
            print("\(item.id.uuidString)\t\(item.label)\t\(attached)\t\(item.connectedAt)")
        }
    }

    static func handleDetachClient(_ args: [String], client: DaemonClient) throws {
        guard let raw = flagValue(args, flag: "--client"), let id = UUID(uuidString: raw) else {
            fputs("Usage: harness-cli detach-client --client <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .detachClient(clientID: id))
    }

    static func handleBindKey(_ args: [String]) throws {
        // Usage: harness-cli bind-key [-T <table>] <spec> <command source>
        let table = flagValue(args, flag: "-T") ?? "prefix"
        var positional = args
        positional.removeAll { $0 == "-T" }
        if let i = positional.firstIndex(of: table) { positional.remove(at: i) }
        guard positional.count >= 2 else {
            fputs("Usage: harness-cli bind-key [-T <table>] <spec> <command...>\n", stderr)
            exit(1)
        }
        let spec = positional[0]
        let source = positional.dropFirst().joined(separator: " ")
        guard let parsedSpec = KeySpec.parse(spec) else {
            fputs("Invalid key spec: \(spec)\n", stderr)
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
        var positional = args
        positional.removeAll { $0 == "-T" }
        if let i = positional.firstIndex(of: table) { positional.remove(at: i) }
        guard let spec = positional.first, let parsedSpec = KeySpec.parse(spec) else {
            fputs("Usage: harness-cli unbind-key [-T <table>] <spec>\n", stderr)
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
            fputs("Usage: harness-cli set-buffer (--data <text> | --stdin) [--name <name>]\n", stderr)
            exit(1)
        }
        let response = try checkedRequest(client, .setBuffer(name: name, data: data))
        if case let .text(final) = response { print(final) }
    }

    static func handleListBuffers(_ client: DaemonClient) throws {
        let response = try checkedRequest(client, .listBuffers)
        guard case let .buffers(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            print("\(item.name)\t\(item.byteCount)B\t\(item.preview)")
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
            fputs("Usage: harness-cli delete-buffer --name <name>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .deleteBuffer(name: name))
    }

    static func handlePasteBuffer(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli paste-buffer --surface <id> [--name <name>]\n", stderr)
            exit(1)
        }
        let name = flagValue(args, flag: "--name")
        _ = try checkedRequest(client, .pasteBuffer(surfaceID: surface, name: name))
    }

    static func handleSelectLayout(_ args: [String], client: DaemonClient) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr),
              let layout = flagValue(args, flag: "--layout")
        else {
            fputs("Usage: harness-cli select-layout --tab <uuid> --layout <name> [--main <paneUUID>]\n", stderr)
            exit(1)
        }
        let mainPaneID = flagValue(args, flag: "--main").flatMap { UUID(uuidString: $0) }
        _ = try checkedRequest(client, .applyLayout(tabID: tabID, layout: layout, mainPaneID: mainPaneID))
    }

    static func handleCycleLayout(_ args: [String], client: DaemonClient, forward: Bool) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr) else {
            fputs("Usage: harness-cli \(forward ? "next" : "previous")-layout --tab <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, forward ? .nextLayout(tabID: tabID) : .previousLayout(tabID: tabID))
    }

    static func handleRotateWindow(_ args: [String], client: DaemonClient) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr) else {
            fputs("Usage: harness-cli rotate-window --tab <uuid> [--reverse]\n", stderr)
            exit(1)
        }
        let forward = !args.contains("--reverse")
        _ = try checkedRequest(client, .rotatePanes(tabID: tabID, forward: forward))
    }

    static func handleBreakPane(_ args: [String], client: DaemonClient) throws {
        guard let paneStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneStr) else {
            fputs("Usage: harness-cli break-pane --pane <uuid>\n", stderr)
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
            fputs("Usage: harness-cli join-pane --src <uuid> --dst <uuid> --direction horizontal|vertical\n", stderr)
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
            fputs("Usage: harness-cli move-pane --src <uuid> --dst <uuid> [--direction horizontal|vertical]\n", stderr)
            exit(1)
        }
        let direction = flagValue(args, flag: "--direction").flatMap(SplitDirection.init(rawValue:)) ?? .horizontal
        let response = try checkedRequest(client, .joinPane(sourcePaneID: src, destPaneID: dst, direction: direction))
        if case let .paneID(id) = response { print(id.uuidString) }
    }

    /// `renumber-windows --session <uuid>` — renumber a session's tab indices.
    static func handleRenumberWindows(_ args: [String], client: DaemonClient) throws {
        guard let sessionStr = flagValue(args, flag: "--session"), let session = UUID(uuidString: sessionStr) else {
            fputs("Usage: harness-cli renumber-windows --session <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .renumberWindows(sessionID: session))
    }

    static func handleRespawnPane(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli respawn-pane --surface <id> [--clear-history]\n", stderr)
            exit(1)
        }
        let keepHistory = !args.contains("--clear-history")
        _ = try checkedRequest(client, .respawnPane(surfaceID: surface, keepHistory: keepHistory))
    }

    static func handleSelectPane(_ args: [String], client: DaemonClient) throws {
        guard let paneStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneStr) else {
            fputs("Usage: harness-cli select-pane --pane <uuid> --dir L|R|U|D\n", stderr)
            exit(1)
        }
        guard let dirStr = flagValue(args, flag: "--dir")?.lowercased(),
              let axis = DirectionalAxis(short: dirStr)
        else {
            fputs("Usage: harness-cli select-pane --pane <uuid> --dir L|R|U|D\n", stderr)
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
        let positional = args.filter { !$0.hasPrefix("-") && $0 != target }
        guard positional.count >= 2 else {
            fputs("Usage: harness-cli set-option [-g|-w|-s|-t|-p] [-T <target>] <key> <value>\n", stderr)
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
        for item in items.sorted(by: { $0.key < $1.key }) {
            let prefix = item.target.map { "\(item.scope):\($0)" } ?? item.scope
            print("\(prefix)\t\(item.key)\t\(item.value)")
        }
    }

    static func handleSetEnvironment(_ args: [String], client: DaemonClient) throws {
        // Usage: set-environment [-g] [-u] [-s <sessionID>] <key> [value]
        // -g = global (default when no -s); -u = unset; -s targets a session.
        let global = args.contains("-g")
        let unset = args.contains("-u")
        let sessionRaw = flagValue(args, flag: "-s")
        let sessionID = (global ? nil : sessionRaw).flatMap(UUID.init(uuidString:))
        let positional = args.filter { !$0.hasPrefix("-") && $0 != sessionRaw }
        guard let key = positional.first else {
            fputs("Usage: harness-cli set-environment [-g] [-u] [-s <sessionID>] <key> [value]\n", stderr)
            exit(1)
        }
        let value = unset ? nil : positional.dropFirst().joined(separator: " ")
        _ = try checkedRequest(client, .setEnvironment(sessionID: sessionID, key: key, value: value))
    }

    static func handleShowEnvironment(_ args: [String], client: DaemonClient) throws {
        let sessionID = args.contains("-g") ? nil : flagValue(args, flag: "-s").flatMap(UUID.init(uuidString:))
        let response = try checkedRequest(client, .showEnvironment(sessionID: sessionID))
        guard case let .options(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            print("\(item.key)=\(item.value)")
        }
    }

    static func handleBindHook(_ args: [String], client: DaemonClient) throws {
        guard args.count >= 3 else {
            fputs("Usage: harness-cli bind-hook <event> <command...> [--if <format>]\n", stderr)
            exit(1)
        }
        let event = args[0]
        let ifIndex = args.firstIndex(of: "--if")
        let condition = (ifIndex.flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil })
        let source: String
        if let ifIndex {
            source = args[1..<ifIndex].joined(separator: " ")
        } else {
            source = args.dropFirst().joined(separator: " ")
        }
        let response = try checkedRequest(client, .bindHook(event: event, source: source, condition: condition))
        if case let .hookID(id) = response { print(id.uuidString) }
    }

    static func handleUnbindHook(_ args: [String], client: DaemonClient) throws {
        guard let raw = flagValue(args, flag: "--id"), let id = UUID(uuidString: raw) else {
            fputs("Usage: harness-cli unbind-hook --id <uuid>\n", stderr)
            exit(1)
        }
        _ = try checkedRequest(client, .unbindHook(id: id))
    }

    static func handleListHooks(_ args: [String], client: DaemonClient) throws {
        let event = flagValue(args, flag: "--event")
        let response = try checkedRequest(client, .listHooks(event: event))
        guard case let .hooks(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            let cond = item.condition.map { " if '\($0)'" } ?? ""
            print("\(item.id.uuidString)\t\(item.event)\t\(item.commandSource)\(cond)")
        }
    }

    static func handleDisplayMessage(_ args: [String], client: DaemonClient) throws {
        let format = args.joined(separator: " ")
        guard !format.isEmpty else {
            fputs("Usage: harness-cli display-message <format>\n", stderr)
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
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        print(dest.path)
        print("export PATH=\"\(dest.deletingLastPathComponent().path):$PATH\"")
        // Install the LaunchAgent so the daemon survives reboot.
        if let daemon = locateDaemonBinary() {
            do {
                let report = try LaunchAgentInstaller.install(daemonPath: daemon)
                print("launch-agent: \(report.plistPath.path)")
            } catch {
                fputs("warning: LaunchAgent install failed: \(error)\n", stderr)
            }
        } else {
            fputs("warning: HarnessDaemon binary not found; LaunchAgent not installed\n", stderr)
        }
        // Shell completions (fish only for now — zsh/bash land in a follow-up).
        do {
            let url = try ShellCompletionInstaller.installFishCompletion()
            print("fish-completion: \(url.path)")
        } catch {
            fputs("warning: fish completion install failed: \(error)\n", stderr)
        }
    }

    /// Locate the daemon executable next to the running CLI. The CLI is
    /// expected to be either (a) inside Harness.app's MacOS folder, where
    /// HarnessDaemon is a sibling, or (b) in `.build/<config>/` during dev.
    static func locateDaemonBinary() -> URL? {
        let cli = CLIInstallLocator.sourceBinary()
        let candidate = cli.deletingLastPathComponent().appendingPathComponent("HarnessDaemon")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        // Try the installed app bundle.
        let appCandidate = URL(fileURLWithPath: "/Applications/Harness.app/Contents/MacOS/HarnessDaemon")
        if FileManager.default.fileExists(atPath: appCandidate.path) { return appCandidate }
        return nil
    }

    static func flagValue(_ args: [String], flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func checkedRequest(_ client: DaemonClient, _ request: IPCRequest) throws -> IPCResponse {
        let response = try client.request(request)
        if case let .error(message) = response {
            throw DaemonSessionError.daemonError(message)
        }
        return response
    }

    static func printUsage() {
        print("""
        harness-cli — control Harness terminal sessions

        Commands:
          list-workspaces
          list-surfaces
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
          install-hooks <codex|claude-code|cursor|pi|hermes|openclaw|aider|gemini|goose>
          attach --surface <uuid> [--detach-keys "C-a d"]
          notify --surface <uuid> [--title t] [--body b]
          daemon-stats
          list-clients
          detach-client --client <uuid>
          bind-key [-T <table>] <spec> <command...>
          unbind-key [-T <table>] <spec>
          list-keys [-T <table>]
          set-buffer (--data <text> | --stdin) [--name <name>]
          list-buffers
          show-buffer [--name <name>]
          delete-buffer --name <name>
          paste-buffer --surface <uuid> [--name <name>]
          select-layout --tab <uuid> --layout even-horizontal|even-vertical|main-horizontal|main-vertical|tiled
          next-layout --tab <uuid>
          previous-layout --tab <uuid>
          rotate-window --tab <uuid> [--reverse]
          break-pane --pane <uuid>
          join-pane --src <uuid> --dst <uuid> --direction horizontal|vertical
          respawn-pane --surface <id> [--clear-history]
          select-pane --pane <uuid> --dir L|R|U|D
          set-option [-g|-w|-s|-t|-p] [-T target] <key> <value>
          show-options [-g|-w|-s|-t|-p]
          set-environment [-g] [-u] [-s <sessionID>] <key> [value]
          show-environment [-g] [-s <sessionID>]
          bind-hook <event> <command...> [--if <format>]
          unbind-hook --id <uuid>
          list-hooks [--event <event>]
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
