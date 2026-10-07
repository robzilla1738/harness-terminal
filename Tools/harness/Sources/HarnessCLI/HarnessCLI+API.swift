import Foundation
import HarnessCore
import HarnessTerminalEngine

extension HarnessCLI {
    /// `api` exits itself. The outer `catch` in `main` turns thrown errors into exit 1,
    /// which would hide exit 2 and exit 3.
    static func handleAPI(_ args: [String]) -> Never {
        let sub = args.count > 1 ? args[1] : ""
        switch sub {
        case "list":
            do {
                print(try HarnessAPI.listJSON())
                exit(0)
            } catch {
                fputs("api list: \(error)\n", harnessStderr)
                exit(1)
            }
        case "describe":
            guard args.count > 2 else {
                fputs("Usage: harness-cli api describe <method>\n", harnessStderr)
                exit(2)
            }
            do {
                print(try HarnessAPI.describeJSON(named: args[2]))
                exit(0)
            } catch let error as APIPlanError {
                fputs("\(error.message)\n", harnessStderr)
                exit(Int32(error.code.rawValue))
            } catch {
                fputs("api describe: \(error)\n", harnessStderr)
                exit(1)
            }
        case "call":
            guard args.count > 2 else {
                fputs("Usage: harness-cli api call <method> --args '{...}'\n", harnessStderr)
                exit(2)
            }
            callAPI(method: args[2], args: args)
        default:
            fputs("Usage: harness-cli api list|describe|call <method> --args '{...}'\n", harnessStderr)
            exit(2)
        }
    }

    private static func callAPI(method name: String, args: [String]) -> Never {
        guard let spec = HarnessAPI.method(named: name) else {
            fputs("Unknown method \(name)\n", harnessStderr)
            exit(2)
        }
        let parsed: [String: APIArgument]
        switch HarnessAPI.arguments(from: flagValue(args, flag: "--args") ?? "{}") {
        case let .success(value):
            parsed = value
        case let .failure(error):
            fputs("\(error.message)\n", harnessStderr)
            exit(Int32(error.code.rawValue))
        }
        if spec.parameters.additionalProperties != true {
            let allowed = Set(spec.parameters.properties?.keys.map { $0 } ?? [])
            if let key = parsed.keys.filter({ !allowed.contains($0) }).sorted().first {
                fputs("Unknown argument \(key)\n", harnessStderr)
                exit(2)
            }
        }
        for required in spec.parameters.required ?? [] where parsed[required] == nil {
            fputs("Missing argument \(required)\n", harnessStderr)
            exit(2)
        }
        let client: DaemonClient
        do {
            client = try makeClient(args)
        } catch {
            fputs("\(error)\n", harnessStderr)
            exit(4)
        }
        let catalog: APICatalog
        do {
            catalog = try loadCatalog(client)
        } catch {
            fputs("\(error)\n", harnessStderr)
            exit(4)
        }
        let planned = HarnessAPI.plan(
            method: name,
            arguments: parsed,
            catalog: catalog,
            environment: APIEnvironment()
        )
        if case let .failure(code, message) = planned {
            fputs(message + "\n", harnessStderr)
            exit(Int32(code))
        }
        do {
            try perform(planned, client: client)
        } catch DaemonClientError.connectionFailed, DaemonClientError.writeFailed {
            fputs("HarnessDaemon is not reachable\n", harnessStderr)
            exit(4)
        } catch {
            fputs("\(error)\n", harnessStderr)
            exit(1)
        }
        exit(0)
    }

    private static func loadCatalog(_ client: DaemonClient) throws -> APICatalog {
        guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
            throw DaemonClientError.unexpectedResponse
        }
        let clients: [ClientSummary]
        if case let .clients(rows) = try client.request(.listClients) {
            clients = rows
        } else {
            clients = []
        }
        return HarnessAPI.catalog(snapshot: snapshot, clients: clients)
    }

    private static func perform(_ plan: APIPlan, client: DaemonClient) throws {
        switch plan {
        case .failure:
            return
        case .version:
            guard case let .daemonStats(stats) = try client.request(.daemonStats) else {
                throw DaemonClientError.unexpectedResponse
            }
            printJSON(VersionBody(
                build: stats.build ?? HarnessVersion.build,
                version: stats.version ?? HarnessVersion.short
            ))
        case .listSessions:
            guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
                throw DaemonClientError.unexpectedResponse
            }
            let sessions = HarnessAPI.catalog(snapshot: snapshot).sessions.map {
                SessionBody(id: $0.id, label: $0.label)
            }
            printJSON(SessionListBody(sessions: sessions))
        case let .viewSession(id):
            guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
                throw DaemonClientError.unexpectedResponse
            }
            guard let view = HarnessAPI.sessionView(snapshot: snapshot, sessionID: id) else {
                fputs("No session \(id)\n", harnessStderr)
                exit(Int32(APIExit.ambiguous.rawValue))
            }
            printJSON(view)
        case let .split(tabID, paneID, direction, command, cwd, layout):
            if let layout {
                guard let tab = UUID(uuidString: tabID) else { throw DaemonClientError.unexpectedResponse }
                let anchor = paneID.flatMap(UUID.init(uuidString:)) ?? tab
                let created = try APILayoutApply.split(tabID: tab, paneID: anchor, layout: layout) { request in
                    try client.request(request, timeout: 10)
                }
                printJSON(PaneBody(pane: created))
                return
            }
            if let command, command.contains(where: { $0 == " " || $0 == "\t" }) {
                fputs("pane.split command must be an executable path\n", harnessStderr)
                exit(2)
            }
            guard let tab = UUID(uuidString: tabID), let splitDirection = SplitDirection(rawValue: direction) else {
                throw DaemonClientError.unexpectedResponse
            }
            let shell = command == "false" ? "/usr/bin/false" : command
            let response = try client.request(.newSplit(
                tabID: tab,
                paneID: paneID.flatMap(UUID.init(uuidString:)),
                direction: splitDirection,
                shell: shell,
                cwd: cwd
            ), timeout: 10)
            guard case let .paneID(created) = response else { throw responseError(response) }
            printJSON(PaneBody(pane: created.uuidString))
        case let .sessionCreate(name, layout):
            guard case let .snapshot(snapshot) = try client.request(.getSnapshot),
                  let workspace = snapshot.workspaces.first
            else { throw DaemonClientError.unexpectedResponse }
            let session = try APILayoutApply.createSession(name: name, layout: layout, workspaceID: workspace.id) { request in
                try client.request(request, timeout: 10)
            }
            printJSON(SessionCreatedBody(session: session))
        case .clientList:
            guard case let .clients(rows) = try client.request(.listClients) else {
                throw DaemonClientError.unexpectedResponse
            }
            printJSON(ClientListBody(clients: rows.map(ClientBody.init)))
        case let .clientDisconnect(id):
            guard let clientID = UUID(uuidString: id) else {
                fputs("client.disconnect id must be a uuid\n", harnessStderr)
                exit(2)
            }
            try requireOK(client.request(.detachClient(clientID: clientID)))
            printJSON(OKBody(ok: true))
        case let .verb(source):
            do {
                try CommandRunner.run(source, client: client, focusSurface: ProcessInfo.processInfo.environment["HARNESS_SURFACE"])
            } catch let failure as CommandRunner.Failure {
                fputs("\(failure)\n", harnessStderr)
                if case .unresolved = failure { exit(CLIExit.targetNotFound) }
                exit(CLIExit.failed)
            }
            printJSON(OKBody(ok: true))
        case let .zoom(paneID):
            guard let pane = UUID(uuidString: paneID) else { throw DaemonClientError.unexpectedResponse }
            try requireOK(client.request(.zoomPane(paneID: pane)))
            printJSON(OKBody(ok: true))
        case let .focus(tabID, paneID):
            guard let tab = UUID(uuidString: tabID), let pane = UUID(uuidString: paneID) else {
                throw DaemonClientError.unexpectedResponse
            }
            try requireOK(client.request(.selectPane(tabID: tab, paneID: pane)))
            printJSON(OKBody(ok: true))
        case let .label(tabID, title):
            guard let tab = UUID(uuidString: tabID) else { throw DaemonClientError.unexpectedResponse }
            try requireOK(client.request(.renameTab(tabID: tab, name: title)))
            printJSON(OKBody(ok: true))
        case let .close(paneID):
            guard let pane = UUID(uuidString: paneID) else { throw DaemonClientError.unexpectedResponse }
            try requireOK(client.request(.killPane(paneID: pane)))
            printJSON(OKBody(ok: true))
        case let .write(surfaceID, text):
            try requireOK(client.request(.send(surfaceID: surfaceID, text: text)))
            printJSON(OKBody(ok: true))
        case let .sendKey(surfaceID, keys, hex):
            if hex {
                try requireOK(client.request(.sendData(surfaceID: surfaceID, data: KeyTokenParser.hexBytes(keys))))
            } else {
                try requireOK(client.request(.sendKeys(surfaceID: surfaceID, keys: keys)))
            }
            printJSON(OKBody(ok: true))
        case let .capture(surfaceID, format, trim, unwrap):
            let response = try client.request(
                .captureFormatted(surfaceID: surfaceID, format: format, trim: trim, unwrap: unwrap),
                timeout: 10
            )
            guard case let .text(text) = response else { throw responseError(response) }
            printJSON(CaptureBody(format: format, text: text))
        case let .process(surfaceID):
            let response = try client.request(.processTree(surfaceID: surfaceID))
            guard case let .text(text) = response else { throw responseError(response) }
            print(text)
        case let .pwd(surfaceID):
            try printQuery(.paneQuery(surfaceID: surfaceID, kind: "pwd"), client: client)
        case let .listDir(surfaceID, path):
            try printQuery(.listDir(surfaceID: surfaceID, path: path), client: client)
        case let .title(surfaceID):
            try printQuery(.paneQuery(surfaceID: surfaceID, kind: "title"), client: client)
        case let .size(surfaceID):
            try printQuery(.paneQuery(surfaceID: surfaceID, kind: "size"), client: client)
        case let .programStatus(surfaceID):
            try printQuery(.paneQuery(surfaceID: surfaceID, kind: "program_status"), client: client)
        case let .wait(surfaceID, until, timeout):
            let response = try client.request(
                .paneWait(surfaceID: surfaceID, until: until, timeout: timeout),
                timeout: timeout + 5
            )
            switch response {
            case let .text(body):
                struct ExitBody: Decodable { var exit: Int }
                guard let parsed = try? JSONDecoder().decode(ExitBody.self, from: Data(body.utf8)) else {
                    fputs("pane.wait: \(body)\n", harnessStderr)
                    exit(1)
                }
                print(body)
                exit(Int32(parsed.exit))
            case let .error(message):
                fputs(message + "\n", harnessStderr)
                exit(1)
            default:
                throw DaemonClientError.unexpectedResponse
            }
        case let .theme(surfaceID, theme):
            var settings = HarnessSettings.load()
            settings.profiles = HarnessAPI.upsertPaneTheme(settings.profiles, surfaceID: surfaceID, theme: theme)
            try settings.save()
            printJSON(OKBody(ok: true))
        case let .reset(surfaceID):
            try requireOK(client.request(.resetSurface(surfaceID: surfaceID)))
            printJSON(OKBody(ok: true))
        }
    }

    private static func printQuery(_ request: IPCRequest, client: DaemonClient) throws {
        let response = try client.request(request)
        guard case let .text(text) = response else { throw responseError(response) }
        print(text)
    }

    private static func requireOK(_ response: IPCResponse) throws {
        if case .ok = response { return }
        throw responseError(response)
    }

    private static func responseError(_ response: IPCResponse) -> Error {
        if case let .error(message) = response { return FollowStreamError(message: message) }
        return DaemonClientError.unexpectedResponse
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }

    private struct VersionBody: Encodable { var build: Int; var version: String }
    private struct SessionBody: Encodable { var id: String; var label: String }
    private struct SessionListBody: Encodable { var sessions: [SessionBody] }
    private struct PaneBody: Encodable { var pane: String }
    private struct OKBody: Encodable { var ok: Bool }
    private struct CaptureBody: Encodable { var format: String; var text: String }
    private struct SessionCreatedBody: Encodable { var session: String }
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
    private struct ClientListBody: Encodable { var clients: [ClientBody] }
}
