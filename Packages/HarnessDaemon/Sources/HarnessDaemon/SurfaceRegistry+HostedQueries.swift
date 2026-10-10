import Foundation
import HarnessCore
import HarnessTerminalEngine

extension SurfaceRegistry {
    func nonterminalControlError(_ request: IPCRequest) -> IPCResponse? {
        let id: String
        switch request {
        case let .send(surface, _), let .sendData(surface, _), let .sendKeys(surface, _), let .resizeSurface(surface, _, _),
             let .clearHistory(surface), let .respawnPane(surface, _), let .pipePane(surface, _),
             let .ensureSurface(surface, _, _, _, _, _, _), let .attachSurface(surface),
             let .capturePane(surface, _), let .capturePaneRange(surface, _, _, _, _), let .captureFormatted(surface, _, _, _, _),
             let .processTree(surface), let .replayScrollback(surface, _), let .replayScrollbackSequenced(surface, _),
             let .foregroundProcess(surface), let .paneQuery(surface, _), let .listDir(surface, _): id = surface
        default: return nil
        }
        lock.lock()
        let leaf = editor.snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs).flatMap({ $0.rootPane.allLeaves() }).first(where: { $0.surfaceID.uuidString == id })
        lock.unlock()
        guard let leaf, !leaf.paneContent.isTerminal else { return nil }
        return .error(leaf.paneContent.kind == "preview" ? PreviewError.terminal.localizedDescription : PreviewError.unsupported.localizedDescription)
    }

    /// Copy the target and reserve accepted work under the registry lock. Host RPC
    /// runs outside it; handover drains these reservations before moving the lease.
    func hostedTerminalMutation(_ request: IPCRequest) -> IPCResponse? {
        guard SessionHostClient.configured != nil else { return nil }
        let id: String
        switch request {
        case let .send(surface, _), let .sendData(surface, _), let .sendKeys(surface, _),
             let .resizeSurface(surface, _, _), let .clearHistory(surface), let .respawnPane(surface, _), let .pipePane(surface, _): id = surface
        default: return nil
        }
        lock.lock()
        guard !quiesced, !shuttingDown else { lock.unlock(); return .error("Daemon handover is in progress; terminal streams remain available.") }
        guard let pty = sessions[id] else {
            lock.unlock()
            if case .respawnPane = request { return nil }
            return .error("Surface not found.")
        }
        let operation: HostedPtyOperation
        var acknowledge = false
        switch request {
        case let .send(_, text): operation = .input(id, Data(text.utf8)); acknowledge = true
        case let .sendData(_, data): operation = .input(id, data); acknowledge = true
        case let .sendKeys(_, keys): operation = .input(id, encodedKeys(surfaceID: id, keys: keys))
        case let .resizeSurface(_, rows, cols):
            guard TerminalGeometry.isValid(cols: Int(cols), rows: Int(rows)) else { lock.unlock(); return .error("Terminal dimensions exceed the supported grid limit.") }
            operation = .resize(id, rows, cols)
        case .clearHistory: operation = .clear(id)
        case let .pipePane(_, command): operation = .pipe(id, command)
        case let .respawnPane(_, keepHistory):
            let match = editor.tab(forSurfaceKey: id)
            let cwd = match.flatMap { match in editor.snapshot.workspaces.first(where: { $0.id == match.workspaceID })?.sessions.flatMap(\.tabs).first(where: { $0.id == match.tabID })?.cwd }
            operation = .respawn(id, !keepHistory, cwd)
        default: lock.unlock(); return nil
        }
        hostedMutations.enter(); lock.unlock()
        defer { hostedMutations.leave() }
        do {
            let response = try pty.query(operation)
            switch response {
            case .ok: break
            case .state: if case .respawn = operation { break } else { return .error("The session host returned an unexpected terminal-control response.") }
            default: return .error("The session host did not acknowledge this terminal control.")
            }
            if acknowledge {
                lock.lock()
                if sessions[id] === pty { acknowledgeProgramStatusIfCurrentLocked(id) }
                lock.unlock()
            }
            return .ok
        } catch {
            return .error("Terminal control failed: " + error.localizedDescription + ". A timed-out operation may already have been accepted; uncertain input is never replayed automatically.")
        }
    }
    /// Capture, filesystem access, and host RPC run after copying the pane handle.
    /// A failed host query is an explicit error, never an empty capture or invented zero.
    func hostedTerminalQuery(_ request: IPCRequest) -> IPCResponse? {
        guard SessionHostClient.configured != nil else { return nil }
        let id: String
        let operation: HostedPtyOperation?
        switch request {
        case let .capturePane(surface, history): id = surface; operation = .captureScrollback(surface, history)
        case let .capturePaneRange(surface, start, end, escapes, join): id = surface; operation = escapes ? .captureRange(surface, start, end, true) : .captureGrid(surface, start, end, join)
        case let .captureFormatted(surface, format, trim, unwrap, screen): id = surface; operation = .capture(surface, format, trim, unwrap, screen ?? false)
        case let .processTree(surface): id = surface; operation = .processTree(surface)
        case let .replayScrollback(surface, from), let .replayScrollbackSequenced(surface, from): id = surface; operation = .replay(surface, from)
        case let .foregroundProcess(surface): id = surface; operation = .state(surface)
        case let .paneQuery(surface, kind) where kind == "pwd" || kind == "size": id = surface; operation = .state(surface)
        case let .listDir(surface, _): id = surface; operation = .state(surface)
        default: return nil
        }
        lock.lock()
        let pty = sessions[id], suspended = quiesced || shuttingDown
        lock.unlock()
        guard !suspended else { return .error("Daemon handover is in progress; terminal streams remain available.") }
        guard let pty, let operation else { return .error("Surface not found.") }
        do {
            switch try pty.query(operation) {
            case let .text(text): return .text(text)
            case let .replay(text, end):
                if case .replayScrollbackSequenced = request { return .replayResult(text: text, endSequence: end) }
                return .text(text)
            case let .state(state):
                switch request {
                case .foregroundProcess: return .text(ControlPlane.processJSON(pid: Int(state.foregroundPID ?? -1), executable: state.foregroundExecutable ?? ""))
                case let .paneQuery(_, kind):
                    if kind == "size" {
                        guard let rows = state.rows, let cols = state.cols else { return .error("Terminal dimensions are unavailable.") }
                        return .text(String(decoding: try JSONEncoder().encode(SizeQuery(cols: cols, rows: rows)), as: UTF8.self))
                    }
                    guard let cwd = state.cwd else { return .error("The program's working directory is unavailable.") }
                    return .text(String(decoding: try JSONEncoder().encode(PwdQuery(url: HarnessAPI.fileURL(path: cwd), pid: Int(state.foregroundPID ?? -1), name: state.foregroundExecutable ?? "")), as: UTF8.self))
                case let .listDir(_, path):
                    guard let cwd = state.cwd else { return .error("The program's working directory is unavailable.") }
                    return .text(PaneDirectory.json(cwd: cwd, path: path))
                default: return .error("Unexpected session-host query response.")
                }
            case let .error(message): return .error(message)
            default: return .error("Unexpected session-host query response.")
            }
        } catch { return .error("Session host query failed: \(error.localizedDescription). Running programs were preserved.") }
    }
}
