import Foundation

/// The outcome of one API call: a JSON body on success, a message on failure, and the exit
/// status `harness-cli` uses (`pane.wait` exits with the waited-for program's status).
public struct APIResult: Equatable, Sendable {
    public var json: String?
    public var message: String?
    public var exitCode: Int32

    public static func ok(_ json: String, exitCode: Int32 = 0) -> APIResult {
        APIResult(json: json, message: nil, exitCode: exitCode)
    }

    public static func failed(_ message: String, code: APIExit) -> APIResult {
        APIResult(json: nil, message: message, exitCode: Int32(code.rawValue))
    }
}

/// Plans and performs `api call` methods against a daemon. The CLI prints the result;
/// Lua's `harness.call` turns it into a table. One implementation, so they can't drift.
public enum APIExecutor {
    public static func call(
        method: String,
        arguments: [String: APIArgument],
        client: DaemonClient,
        environment: APIEnvironment = APIEnvironment()
    ) -> APIResult {
        do {
            guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
                return .failed("HarnessDaemon sent no snapshot", code: .failed)
            }
            var clients: [ClientSummary] = []
            if case let .clients(rows) = try client.request(.listClients) { clients = rows }
            let catalog = HarnessAPI.catalog(snapshot: snapshot, clients: clients)
            let plan = HarnessAPI.plan(method: method, arguments: arguments, catalog: catalog, environment: environment)
            return try perform(plan, snapshot: snapshot, client: client, environment: environment)
        } catch DaemonClientError.connectionFailed, DaemonClientError.writeFailed, EndpointError.connectionFailed {
            return .failed("HarnessDaemon is not reachable", code: .unreachable)
        } catch let failure as CommandRunner.Failure {
            if case .unresolved = failure { return .failed("\(failure)", code: .ambiguous) }
            return .failed("\(failure)", code: .failed)
        } catch {
            return .failed("\(error)", code: .failed)
        }
    }

    static func perform(_ plan: APIPlan, snapshot: SessionSnapshot, client: DaemonClient, environment: APIEnvironment) throws -> APIResult {
        switch plan {
        case let .failure(code, message):
            return APIResult(json: nil, message: message, exitCode: Int32(code))
        case .version:
            guard case let .daemonStats(stats) = try client.request(.daemonStats) else { throw DaemonClientError.unexpectedResponse }
            return .ok(try encode(["version": stats.version ?? HarnessVersion.short, "build": String(stats.build ?? HarnessVersion.build)]))
        case .listSessions:
            let sessions = HarnessAPI.catalog(snapshot: snapshot).sessions.map { ["id": $0.id, "label": $0.label] }
            return .ok(try encode(["sessions": sessions]))
        case let .viewSession(id):
            guard let view = HarnessAPI.sessionView(snapshot: snapshot, sessionID: id) else {
                return .failed("No session \(id)", code: .ambiguous)
            }
            return .ok(try encode(view))
        case let .viewPane(surfaceID):
            return .ok(try paneView(surfaceID, snapshot: snapshot, client: client))
        case let .split(tabID, paneID, direction, command, cwd, layout):
            guard let tab = UUID(uuidString: tabID) else { throw DaemonClientError.unexpectedResponse }
            if let layout {
                let anchor = paneID.flatMap(UUID.init(uuidString:)) ?? tab
                let created = try APILayoutApply.split(tabID: tab, paneID: anchor, layout: layout) { try client.request($0, timeout: 10) }
                return .ok(try encode(["pane": created]))
            }
            if let command, command.contains(where: { $0 == " " || $0 == "\t" }) {
                return .failed("pane.split command must be an executable path", code: .badArguments)
            }
            guard let splitDirection = SplitDirection(rawValue: direction) else { throw DaemonClientError.unexpectedResponse }
            let shell = command == "false" ? "/usr/bin/false" : command
            return try reply(client.request(.newSplit(
                tabID: tab, paneID: paneID.flatMap(UUID.init(uuidString:)), direction: splitDirection, shell: shell, cwd: cwd
            ), timeout: 10))
        case let .sessionCreate(name, layout):
            guard let workspace = snapshot.activeWorkspace ?? snapshot.workspaces.first else { throw DaemonClientError.unexpectedResponse }
            let session = try APILayoutApply.createSession(name: name, layout: layout, workspaceID: workspace.id) { try client.request($0, timeout: 10) }
            return .ok(try encode(["session": session]))
        case .clientList:
            guard case let .clients(rows) = try client.request(.listClients) else { throw DaemonClientError.unexpectedResponse }
            return .ok(try encode(["clients": rows.map(ClientBody.init)]))
        case let .clientDisconnect(id):
            guard let clientID = UUID(uuidString: id) else { return .failed("client.disconnect id must be a uuid", code: .badArguments) }
            return try reply(client.request(.detachClient(clientID: clientID)))
        case let .verb(source):
            try CommandRunner.run(source, client: client, focusSurface: environment.surface)
            return .ok(try encode(["ok": true]))
        case let .request(request):
            return try reply(client.request(request, timeout: 10))
        case let .query(request):
            let response = try client.request(request, timeout: 10)
            guard case let .text(text) = response else { return try reply(response) }
            return .ok(text)
        case let .sendKey(surfaceID, keys, hex):
            let request: IPCRequest = hex
                ? .sendData(surfaceID: surfaceID, data: HexKeys.bytes(keys))
                : .sendKeys(surfaceID: surfaceID, keys: keys)
            return try reply(client.request(request))
        case let .capture(surfaceID, format, trim, unwrap, screen):
            let response = try client.request(.captureFormatted(surfaceID: surfaceID, format: format, trim: trim, unwrap: unwrap, screen: screen), timeout: 10)
            guard case let .text(text) = response else { return try reply(response) }
            return .ok(try encode(["format": format, "text": text]))
        case let .wait(surfaceID, until, timeout):
            let response = try client.request(.paneWait(surfaceID: surfaceID, until: until, timeout: timeout), timeout: timeout + 5)
            guard case let .text(body) = response else { return try reply(response) }
            struct ExitBody: Decodable { var exit: Int32 }
            guard let parsed = try? JSONDecoder().decode(ExitBody.self, from: Data(body.utf8)) else {
                return .failed("pane.wait: \(body)", code: .failed)
            }
            return .ok(body, exitCode: parsed.exit)
        case let .theme(surfaceID, theme):
            var settings = HarnessSettings.load()
            settings.profiles = HarnessAPI.upsertPaneTheme(settings.profiles, surfaceID: surfaceID, theme: theme)
            try settings.save()
            return .ok(try encode(["ok": true]))
        }
    }

    /// A daemon reply as the result: `ok`, or the id it created.
    private static func reply(_ response: IPCResponse) throws -> APIResult {
        switch response {
        case .ok: return .ok(try encode(["ok": true]))
        case let .text(json): return .ok(json)
        case let .tabID(id): return .ok(try encode(["tab": id.uuidString]))
        case let .paneID(id): return .ok(try encode(["pane": id.uuidString]))
        case let .sessionID(id): return .ok(try encode(["session": id.uuidString]))
        case let .surfaceID(id): return .ok(try encode(["surface": id]))
        case let .error(message): return .failed(message, code: .failed)
        default: throw DaemonClientError.unexpectedResponse
        }
    }

    /// `pane.view`: the pane's ids and identity from the snapshot, plus the daemon's live
    /// size, program status, and process tree.
    private static func paneView(_ surfaceID: String, snapshot: SessionSnapshot, client: DaemonClient) throws -> String {
        var view: [String: Any] = ["surface": surfaceID]
        for session in snapshot.workspaces.flatMap(\.sessions) {
            for tab in session.tabs {
                guard let leaf = tab.rootPane.allLeaves().first(where: { $0.surfaceID.uuidString == surfaceID }) else { continue }
                let identity = PaneIdentity.of(leaf: leaf, in: tab)
                view["pane"] = leaf.id.uuidString
                view["tab"] = tab.id.uuidString
                view["session"] = session.id.uuidString
                view["cwd"] = identity.directory
                view["command"] = identity.program ?? NSNull()
                view["agent"] = identity.agent?.commandToken ?? NSNull()
            }
        }
        for (key, request) in [
            ("size", IPCRequest.paneQuery(surfaceID: surfaceID, kind: "size")),
            ("status", IPCRequest.paneQuery(surfaceID: surfaceID, kind: "program_status")),
            ("process", IPCRequest.processTree(surfaceID: surfaceID)),
        ] {
            if case let .text(text) = try client.request(request, timeout: 5),
               let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) {
                view[key] = value
            }
        }
        let data = try JSONSerialization.data(withJSONObject: view, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private struct ClientBody: Encodable {
        var id: String
        var kind: String
        var version: String
        var principal: Principal
        var age: Double

        struct Principal: Encodable { var uid: UInt32?; var local: Bool }

        init(_ summary: ClientSummary) {
            id = summary.id.uuidString
            kind = summary.kind
            version = summary.version
            principal = Principal(uid: summary.principalUID, local: !summary.tunnel)
            age = summary.age
        }
    }
}
