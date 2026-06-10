import Foundation
import HarnessCore
import HarnessTerminalEngine

/// Pane/window manipulation subcommands (send-keys, capture/pipe, swap/resize/select/
/// break/join/move/respawn, layouts, link/unlink, renumber, copy-mode, wait-for, clear-
/// history). Mechanically extracted from `HarnessCLI.swift` (PR-32): zero logic change.
extension HarnessCLI {
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
        let mode: WaitForMode
        if args.contains("-S") { mode = .signal }
        else if args.contains("-L") { mode = .lock }
        else if args.contains("-U") { mode = .unlock }
        else { mode = .wait }
        guard let channel = positionalArgs(args, skippingValuesFor: []).first else {
            fputs("Usage: harness-cli wait-for [-S|-L|-U] <channel>\n", harnessStderr)
            exit(1)
        }
        // `wait`/`lock` block until signaled/granted — a generous (≈1 week) timeout, well
        // within the poll's Int32 millisecond range. `signal`/`unlock` return at once.
        let timeout: TimeInterval = (mode == .wait || mode == .lock) ? 604_800 : 5
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

    /// `clear-history`: drop a surface's scrollback WITHOUT respawning the shell (unlike
    /// `respawn-pane -k`, which kills the running process). The daemon also pushes `ESC[3J` to
    /// attached clients so their on-screen scrollback clears in step with the server's ring.
    static func handleClearHistory(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli clear-history --surface <id>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .clearHistory(surfaceID: surface))
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
}
