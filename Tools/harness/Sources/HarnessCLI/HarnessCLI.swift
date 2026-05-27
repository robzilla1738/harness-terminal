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
                let response = try client.request(.newWorkspace(name: name))
                if case let .workspaceID(id) = response { print(id.uuidString) }
            case "new-tab":
                try handleNewTab(args, client: client)
            case "new-split":
                try handleNewSplit(args, client: client)
            case "select-workspace":
                try handleSelectWorkspace(args, client: client)
            case "select-tab":
                try handleSelectTab(args, client: client)
            case "close-tab":
                guard let tabID = UUID(uuidString: flagValue(args, flag: "--tab") ?? "") else {
                    fputs("Usage: harness-cli close-tab --tab <uuid>\n", stderr)
                    exit(1)
                }
                _ = try client.request(.closeTab(tabID: tabID))
            case "send":
                guard let surface = flagValue(args, flag: "--surface"),
                      let text = flagValue(args, flag: "--text")
                else {
                    fputs("Usage: harness-cli send --surface <uuid> --text \"...\"\n", stderr)
                    exit(1)
                }
                _ = try client.request(.send(surfaceID: surface, text: text))
            case "notify":
                guard let surface = flagValue(args, flag: "--surface") else {
                    fputs("Usage: harness-cli notify --surface <uuid> [--title t] [--body b]\n", stderr)
                    exit(1)
                }
                let title = flagValue(args, flag: "--title") ?? "Agent"
                let body = flagValue(args, flag: "--body") ?? flagValue(args, flag: "--message") ?? "Needs attention"
                _ = try client.request(.notify(surfaceID: surface, title: title, body: body))
            case "install":
                try installCLI()
            case "ping":
                let response = try client.request(.ping)
                print(response)
            case "send-keys":
                try handleSendKeys(args, client: client)
            case "capture-pane":
                try handleCapturePane(args, client: client)
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
            case "rename-workspace":
                try handleRenameWorkspace(args, client: client)
            case "detect-agent":
                try handleDetectAgent(args, client: client)
            case "install-hooks":
                try handleInstallHooks(args)
            case "attach":
                try handleAttach(args, client: client)
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
            let response = try client.request(.newTabInWorkspace(named: name, cwd: cwd))
            if case let .tabID(id) = response { print(id.uuidString) }
            return
        }
        guard let workspaceID = UUID(uuidString: flagValue(args, flag: "--workspace-id") ?? "") else {
            fputs("Usage: harness-cli new-tab --workspace <name|uuid> [--cwd path]\n", stderr)
            exit(1)
        }
        let cwd = flagValue(args, flag: "--cwd")
        let response = try client.request(.newTab(workspaceID: workspaceID, cwd: cwd))
        if case let .tabID(id) = response { print(id.uuidString) }
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
        let response = try client.request(.newSplit(tabID: tabID, paneID: paneID, direction: direction))
        if case let .paneID(id) = response { print(id.uuidString) }
    }

    static func handleSelectWorkspace(_ args: [String], client: DaemonClient) throws {
        guard let target = flagValue(args, flag: "--workspace") ?? flagValue(args, flag: "--id") else {
            fputs("Usage: harness-cli select-workspace --workspace <name|uuid>\n", stderr)
            exit(1)
        }
        if let uuid = UUID(uuidString: target) {
            _ = try client.request(.selectWorkspace(id: uuid))
        } else {
            _ = try client.request(.selectWorkspaceByName(name: target))
        }
    }

    static func handleSelectTab(_ args: [String], client: DaemonClient) throws {
        guard let workspaceID = UUID(uuidString: flagValue(args, flag: "--workspace") ?? ""),
              let tabID = UUID(uuidString: flagValue(args, flag: "--tab") ?? "")
        else {
            fputs("Usage: harness-cli select-tab --workspace <uuid> --tab <uuid>\n", stderr)
            exit(1)
        }
        _ = try client.request(.selectTab(workspaceID: workspaceID, tabID: tabID))
    }

    static func printWorkspaces(_ client: DaemonClient) throws {
        let response = try client.request(.listWorkspaces)
        guard case let .workspaces(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            print("\(item.id)\t\(item.name)\t\(item.tabCount) tabs")
        }
    }

    static func printSurfaces(_ client: DaemonClient) throws {
        let response = try client.request(.listSurfaces)
        guard case let .surfaces(items) = response else { throw DaemonClientError.unexpectedResponse }
        for item in items {
            print("\(item.surfaceID)\t\(item.workspaceName)\t\(item.tabTitle)\t\(item.cwd)")
        }
    }

    static func printSnapshot(_ client: DaemonClient) throws {
        let response = try client.request(.getSnapshot)
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
        _ = try client.request(.sendKeys(surfaceID: surface, keys: tokens))
    }

    static func handleCapturePane(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli capture-pane --surface <id> [--scrollback]\n", stderr)
            exit(1)
        }
        let scrollback = args.contains("--scrollback")
        let response = try client.request(.capturePane(surfaceID: surface, includeScrollback: scrollback))
        if case let .text(text) = response {
            print(text)
        }
    }

    static func handlePaneCommand(_ args: [String], client: DaemonClient, _ make: (UUID) -> IPCRequest) throws {
        guard let paneIDStr = flagValue(args, flag: "--pane"), let paneID = UUID(uuidString: paneIDStr) else {
            fputs("Missing or invalid --pane <uuid>\n", stderr)
            exit(1)
        }
        _ = try client.request(make(paneID))
    }

    static func handleSwapPane(_ args: [String], client: DaemonClient) throws {
        guard let srcStr = flagValue(args, flag: "--src"), let src = UUID(uuidString: srcStr),
              let dstStr = flagValue(args, flag: "--dst"), let dst = UUID(uuidString: dstStr)
        else {
            fputs("Usage: harness-cli swap-pane --src <uuid> --dst <uuid>\n", stderr)
            exit(1)
        }
        _ = try client.request(.swapPanes(srcPaneID: src, dstPaneID: dst))
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
        _ = try client.request(.resizePane(paneID: paneID, direction: direction, amount: amount))
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
        _ = try client.request(.setCopyMode(surfaceID: surface, enabled: enabled))
    }

    static func handleRenameTab(_ args: [String], client: DaemonClient) throws {
        guard let tabStr = flagValue(args, flag: "--tab"), let tabID = UUID(uuidString: tabStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-tab --tab <uuid> --name \"...\"\n", stderr)
            exit(1)
        }
        _ = try client.request(.renameTab(tabID: tabID, name: name))
    }

    static func handleRenameWorkspace(_ args: [String], client: DaemonClient) throws {
        guard let idStr = flagValue(args, flag: "--id") ?? flagValue(args, flag: "--workspace"),
              let id = UUID(uuidString: idStr),
              let name = flagValue(args, flag: "--name")
        else {
            fputs("Usage: harness-cli rename-workspace --id <uuid> --name \"...\"\n", stderr)
            exit(1)
        }
        _ = try client.request(.renameWorkspace(workspaceID: id, name: name))
    }

    static func handleDetectAgent(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli detect-agent --surface <id>\n", stderr)
            exit(1)
        }
        let response = try client.request(.detectAgent(surfaceID: surface))
        if case let .agentInfo(info) = response, let info {
            print("\(info.kind.rawValue)\t\(info.executable)\t\(info.activity.rawValue)")
        }
    }

    static func handleInstallHooks(_ args: [String]) throws {
        let agent = args.dropFirst().first ?? flagValue(args, flag: "--agent") ?? ""
        try AgentHookInstaller.install(agent: agent)
    }

    static func handleAttach(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli attach --surface <id>\n", stderr)
            exit(1)
        }
        // Phase 5 will plumb full streaming; for now we replay scrollback so the
        // user can confirm a pane's recent output without launching the GUI.
        let response = try client.request(.replayScrollback(surfaceID: surface, fromSequence: nil))
        if case let .text(text) = response { print(text) }
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
    }

    static func flagValue(_ args: [String], flag: String) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    static func printUsage() {
        print("""
        harness-cli — control Harness terminal sessions

        Commands:
          list-workspaces
          list-surfaces
          get-snapshot
          new-workspace --name <name>
          new-tab --workspace <name|uuid> [--cwd path]
          new-split --tab <uuid> --direction horizontal|vertical [--pane <uuid>]
          select-workspace --workspace <name|uuid>
          select-tab --workspace <uuid> --tab <uuid>
          close-tab --tab <uuid>
          send --surface <uuid> --text "..."
          send-keys --surface <uuid> --keys "C-c Up Enter ..."
          capture-pane --surface <uuid> [--scrollback]
          kill-pane --pane <uuid>
          swap-pane --src <uuid> --dst <uuid>
          resize-pane --pane <uuid> --dir L|R|U|D [--amount N]
          zoom-pane --pane <uuid>
          copy-mode --surface <uuid> [--enter|--exit]
          rename-tab --tab <uuid> --name "..."
          rename-workspace --id <uuid> --name "..."
          detect-agent --surface <uuid>
          install-hooks <codex|claude-code|cursor|pi|hermes|openclaw|aider|gemini|goose>
          attach --surface <uuid>
          notify --surface <uuid> [--title t] [--body b]
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

extension DaemonClientError {
    static var unexpectedResponse: DaemonClientError {
        .connectionFailed
    }
}
