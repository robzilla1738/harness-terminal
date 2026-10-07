import Foundation
import HarnessCore

extension HarnessCLI {
    static let runUsage = """
    Usage: harness-cli run [--split right|below|left|above] [--ratio PCT] [--cwd DIR] [--label TEXT]
                           [--surface TARGET] [--no-focus] [--keep-open] [--wait] [--timeout SECS] [--json] -- COMMAND...
    """

    /// `run`: start a command in a new tab, or in a split of the current (or `--surface`) pane.
    /// The pane closes when the command exits unless `--keep-open`. `--wait` exits with the
    /// command's own status, so scripts and agents can `harness-cli run --wait -- make test`.
    static func handleRun(_ args: [String], client: DaemonClient) throws {
        guard let dashes = args.firstIndex(of: "--"), dashes + 1 < args.count else {
            fputs(runUsage + "\n", harnessStderr)
            exit(CLIExit.usage)
        }
        let options = Array(args[..<dashes])
        let command = ControlPlane.shellJoin(Array(args[(dashes + 1)...]))
        let keepOpen = options.contains("--keep-open")
        let split = flagValue(options, flag: "--split")
        if let split, !["right", "below", "left", "above"].contains(split) {
            fputs("run: --split must be right, below, left, or above\n", harnessStderr)
            exit(CLIExit.usage)
        }
        guard case let .snapshot(snapshot) = try checkedRequest(client, .getSnapshot),
              let workspace = snapshot.activeWorkspace
        else {
            fputs("run: no workspace\n", harnessStderr)
            exit(CLIExit.failed)
        }
        let cwd = flagValue(options, flag: "--cwd").map { ($0 as NSString).expandingTildeInPath }

        // The pane to split, or nil for a new tab.
        let anchor: (tab: Tab, leaf: PaneLeaf)?
        if split != nil {
            let target = flagValue(options, flag: "--surface") ?? ProcessInfo.processInfo.environment["HARNESS_SURFACE"]
            let tabs = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
            if let target, let found = tabs.lazy.compactMap({ tab in
                tab.rootPane.allLeaves().first { $0.surfaceID.uuidString.caseInsensitiveCompare(target) == .orderedSame }.map { (tab, $0) }
            }).first {
                anchor = found
            } else if let tab = workspace.activeTab {
                let leaf = tab.rootPane.allLeaves().first { $0.id == tab.activePaneID } ?? tab.rootPane.allLeaves().first
                anchor = leaf.map { (tab, $0) }
            } else {
                anchor = nil
            }
            if anchor == nil {
                fputs("run: no pane to split\n", harnessStderr)
                exit(CLIExit.targetNotFound)
            }
        } else {
            anchor = nil
        }

        let tabID: UUID
        let paneID: UUID
        if let anchor, let split {
            let direction: SplitDirection = (split == "right" || split == "left") ? .horizontal : .vertical
            guard case let .paneID(newPane) = try checkedRequest(client, .newSplit(
                tabID: anchor.tab.id, paneID: anchor.leaf.id, direction: direction, shell: nil, cwd: cwd
            )) else { throw DaemonClientError.unexpectedResponse }
            if split == "left" || split == "above" {
                _ = try checkedRequest(client, .swapPanes(srcPaneID: newPane, dstPaneID: anchor.leaf.id))
            }
            if let raw = flagValue(options, flag: "--ratio"), let percent = Double(raw), (1 ... 99).contains(percent) {
                let share = split == "left" || split == "above" ? percent / 100 : 1 - percent / 100
                let (first, second) = split == "left" || split == "above" ? (newPane, anchor.leaf.id) : (anchor.leaf.id, newPane)
                _ = try? client.request(.resizePaneRatio(tabID: anchor.tab.id, firstPaneID: first, secondPaneID: second, ratio: share))
            }
            tabID = anchor.tab.id
            paneID = newPane
            if options.contains("--no-focus") {
                _ = try? client.request(.selectPane(tabID: anchor.tab.id, paneID: anchor.leaf.id))
            }
        } else {
            guard case let .tabID(newTab) = try checkedRequest(client, .newTab(workspaceID: workspace.id, cwd: cwd, shell: nil)),
                  case let .snapshot(after) = try checkedRequest(client, .getSnapshot),
                  let tab = after.workspaces.flatMap(\.sessions).flatMap(\.tabs).first(where: { $0.id == newTab }),
                  let leaf = tab.rootPane.allLeaves().first
            else { throw DaemonClientError.unexpectedResponse }
            tabID = newTab
            paneID = leaf.id
        }
        guard case let .snapshot(after) = try checkedRequest(client, .getSnapshot),
              let surface = after.workspaces.flatMap(\.sessions).flatMap(\.tabs)
                .flatMap({ $0.rootPane.allLeaves() }).first(where: { $0.id == paneID })?.surfaceID.uuidString
        else { throw DaemonClientError.unexpectedResponse }
        if let label = flagValue(options, flag: "--label") {
            _ = try? client.request(.renameTab(tabID: tabID, name: label))
        }

        // `; exit` hands the command's status to the shell's own exit, so the pane closes
        // with it and `--wait` can read it from the child.
        _ = try checkedRequest(client, .send(surfaceID: surface, text: keepOpen ? command + "\n" : command + "; exit\n"))

        if options.contains("--json") {
            let body = ["surface": surface, "pane": paneID.uuidString, "tab": tabID.uuidString]
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else if !options.contains("--wait") {
            print(surface)
        }
        guard options.contains("--wait") else { return }
        let timeout = flagValue(options, flag: "--timeout").flatMap(Double.init) ?? 24 * 3600
        // A waiting client can block for the whole run; give the socket the same budget.
        let response = try client.request(.paneWait(surfaceID: surface, until: keepOpen ? "command" : "child", timeout: timeout), timeout: timeout + 5)
        switch response {
        case let .text(body):
            struct ExitBody: Decodable { var exit: Int32 }
            let status = (try? JSONDecoder().decode(ExitBody.self, from: Data(body.utf8)))?.exit ?? CLIExit.failed
            exit(status)
        case let .error(message):
            fputs("run: \(message)\n", harnessStderr)
            exit(CLIExit.failed)
        default:
            throw DaemonClientError.unexpectedResponse
        }
    }
}
