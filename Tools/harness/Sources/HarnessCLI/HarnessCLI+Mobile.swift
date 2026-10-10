#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore
import HarnessRemoteProtocol

extension HarnessCLI {
    static func handleMobileBridge(_ args: [String]) throws {
        guard args.contains("--stdio"), flagValue(args, flag: "--protocol") == "1", isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 else {
            throw RemoteFailure(code: "unsupportedProtocol", message: "Use mobile-bridge --stdio --protocol 1 on a non-PTY SSH channel")
        }
        signal(SIGPIPE, SIG_IGN)
        let bridge = MobileBridge(client: DaemonClient(endpoint: .localControlSocket))
        try bridge.run()
    }

    static func handleMobileSetup(_ args: [String]) throws {
        let info = try mobilePairingInfo(args)
        if args.contains("--json") { print(String(decoding: try JSONEncoder().encode(info), as: UTF8.self)) }
        else if args.contains("--link") { print(try info.connectionURL().absoluteString) }
        else { try printMobilePairing(info) }
    }

    static func mobilePairingInfo(_ args: [String]) throws -> RemotePairingInfo {
        var index = 1
        var flags: Set<String> = []
        while index < args.count {
            let flag = args[index]
            guard ["--host", "--port", "--json", "--link"].contains(flag), flags.insert(flag).inserted else {
                throw RemoteFailure(code: "badArguments", message: "Usage: harness-cli pair [--host <address>] [--port <port>] [--json | --link]")
            }
            if flag == "--host" || flag == "--port" {
                guard index + 1 < args.count, !args[index + 1].isEmpty, !args[index + 1].hasPrefix("--") else {
                    throw RemoteFailure(code: "badArguments", message: "\(flag) requires a value.")
                }
                index += 1
            }
            index += 1
        }
        guard !flags.isSuperset(of: ["--json", "--link"]) else {
            throw RemoteFailure(code: "badArguments", message: "Choose either --json or --link.")
        }
        let localAddresses = try MobileConnectionAddress.available().filter { !$0.isVPN }.map(\.host)
        let tailscale = TailscaleStatus.discover().address
        let host = flagValue(args, flag: "--host") ?? localAddresses.first ?? tailscale
        guard let host else {
            throw RemoteFailure(code: "addressUnavailable", message: "Connect to Wi-Fi or Tailscale, or pass --host <reachable-address>.")
        }
        let portText = flagValue(args, flag: "--port") ?? "22"
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw RemoteFailure(code: "badArguments", message: "Use an SSH port from 1 to 65535.")
        }
        let key = "/etc/ssh/ssh_host_ed25519_key.pub"
        guard FileManager.default.fileExists(atPath: key) else {
            throw RemoteFailure(code: "hostKeyUnavailable", message: "Enable SSH on this host first (System Settings → General → Sharing → Remote Login on macOS), then run harness-cli pair again.")
        }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-l", "-f", key, "-E", "sha256"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let fingerprint = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init) else {
            throw RemoteFailure(code: "hostKeyUnavailable", message: "Could not read the SSH host-key fingerprint.")
        }
        let alternatives = Array(([tailscale].compactMap { $0 } + localAddresses).filter { $0 != host }.prefix(4))
        let info = RemotePairingInfo(host: host, port: port, username: NSUserName(), fingerprint: fingerprint,
            executablePath: CLIInstallLocator.sourceBinary().standardizedFileURL.resolvingSymlinksInPath().path,
            alternateHosts: alternatives.isEmpty ? nil : alternatives)
        try info.validate()
        return info
    }

}

/// One bridge per SSH channel: control channels watch state, pane channels carry one exact
/// surface. Daemon subscription fds retain sizing and query-responder semantics.
final class MobileBridge: @unchecked Sendable {
    private let client: DaemonClient
    private let writer = MobileBridgeWriter()
    private let stateLock = NSLock()
    private let refreshQueue = DispatchQueue(label: "com.robert.harness.mobile-refresh")
    private var pane: DaemonSubscription?
    private var watcher: DaemonSubscription?
    private var configurationTimer: DispatchSourceTimer?
    private var configurationStamp = ""
    private var latestAppearance: RemoteAppearance?
    private var currentAttach: HarnessRemoteProtocol.RemoteAttach?
    private var generation = UUID()
    private var latestRevision: Int?
    private var latestAttention: [RemoteAttention]?
    private var finished = false
    private var daemonCapabilities: Set<String> = []

    init(client: DaemonClient) { self.client = client }

    func run() throws {
        guard case let .daemonStats(stats) = try client.request(.daemonStats),
              stats.capabilities?.contains(DaemonStats.mobileCompanion) == true,
              let epoch = stats.epoch else {
            throw RemoteFailure(code: "updateRequired", message: "Update Harness on this host to the companion-ready release and restart Harness when your work permits")
        }
        daemonCapabilities = Set(stats.capabilities ?? [])
        try writer.write(.hello(RemoteHello(cliVersion: HarnessVersion.short, daemonVersion: stats.version ?? "unknown",
            hostName: ProcessInfo.processInfo.hostName, daemonEpoch: epoch,
            capabilities: (stats.capabilities ?? []) + ["appearance", "workspace-tools", "control-rpc", "snapshot-watch", "attention", "pane-attach", "terminal-checkpoint-v1", "resume", "styled-history", "file-upload"])))
        defer { closeAll() }
        var buffer = Data()
        var scratch = [UInt8](repeating: 0, count: 65536)
        while !isFinished() {
            var ready = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 1000)
            if polled < 0, errno == EINTR { continue }
            guard polled >= 0 else { throw RemoteFailure(code: "readFailed", message: "Bridge input failed") }
            if polled == 0 { continue }
            let count = read(STDIN_FILENO, &scratch, scratch.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw RemoteFailure(code: "readFailed", message: "Bridge input failed") }
            if count == 0 { break }
            buffer.append(contentsOf: scratch.prefix(count))
            for message in try RemoteCodec.decode(buffer: &buffer) {
                do { try receive(message) }
                catch let failure as RemoteFailure { emit(.error(failure)) }
                catch { emit(.error(RemoteFailure(code: "operationFailed", message: error.localizedDescription))) }
            }
            guard buffer.count <= RemoteCodec.maximumFrameBytes + 4 else { throw RemoteCodec.Failure.oversizedFrame }
        }
    }

    private func receive(_ message: RemoteMessage) throws {
        switch message {
        case let .request(request):
            do { emit(.response(RemoteResponse(id: request.id, result: try call(request)))) }
            catch {
                let failure = (error as? RemoteFailure) ?? RemoteFailure(code: "operationFailed", message: error.localizedDescription)
                emit(.response(RemoteResponse(id: request.id, failure: failure)))
            }
        case let .attach(attach): try attachPane(attach)
        case let .input(input):
            stateLock.lock(); let attach = currentAttach; let subscription = pane; stateLock.unlock()
            guard let attach, let subscription, input.surfaceID == attach.address.surfaceID, !attach.readOnly else {
                throw RemoteFailure(code: "inputDenied", message: "This pane is not attached in Control mode")
            }
            guard input.data.count <= 1024 * 1024 else { throw RemoteFailure(code: "inputTooLarge", message: "Send input in chunks of at most 1 MiB") }
            guard subscription.sendInput(input.data, surfaceID: input.surfaceID) else {
                throw RemoteFailure(code: "inputDeliveryUnknown", message: "The connection interrupted input. It may have reached the program; it will not be retried.", deliveryUncertain: true)
            }
        case let .resize(resize):
            stateLock.lock(); let attach = currentAttach; let subscription = pane; stateLock.unlock()
            guard let attach, let subscription, !attach.readOnly, resize.surfaceID == attach.address.surfaceID else {
                throw RemoteFailure(code: "resizeDenied", message: "This pane is not attached in Control mode")
            }
            try validateGeometry(cols: resize.cols, rows: resize.rows)
            subscription.resize(resize.surfaceID, rows: resize.rows, cols: resize.cols, takeOwnership: resize.takeOwnership)
        case .detach: detachPane()
        default: throw RemoteFailure(code: "unexpectedMessage", message: "This message is not accepted by the host bridge")
        }
    }

    private func call(_ request: RemoteRequest) throws -> JSONValue {
        let arguments = request.arguments
        if CompanionAPICatalog.method(named: request.method) != nil {
            try CompanionAPICatalog.validate(name: request.method, arguments: arguments.mapValues(companionArgument), exposure: .mobile, capabilities: daemonCapabilities)
        }
        switch request.method {
        case "snapshot.get": return try value(snapshot())
        case "attention.get": return try value(attention())
        case "snapshot.watch":
            if watcher == nil {
                watcher = try client.subscribeSnapshot(label: "Harness Remote activity", onRevision: { [weak self] _ in
                    self?.refreshQueue.async { [weak self] in self?.refresh() }
                }, onEnd: { [weak self] in self?.fail(RemoteFailure(code: "daemonDisconnected", message: "Harness stopped. Reconnect when the host is available.")) })
            }
            refresh()
            startConfigurationWatch()
            return .object(["ok": .bool(true)])
        case "file.upload":
            guard let name = arguments["name"]?.string, !name.isEmpty, name.utf8.count <= 255,
                  let encoded = arguments["data"]?.string, encoded.utf8.count <= 11_184_812,
                  let data = Data(base64Encoded: encoded), data.count <= 8 * 1024 * 1024 else {
                throw RemoteFailure(code: "badArguments", message: "Upload requires a filename and base64 data within the 8 MiB limit")
            }
            guard case let .text(path) = try HarnessCLI.checkedRequest(client, .writeTempFile(name: name, data: data), timeout: 30) else { throw DaemonClientError.unexpectedResponse }
            return .string(path)
        case "device.installKey", "device.removeKey":
            throw CompanionAPIError.denied
        case "pane.history":
            let pane = try resolvePane(arguments["pane"]?.string)
            guard case let .text(json) = try HarnessCLI.checkedRequest(client, .mobileHistory(surfaceID: pane.address.surfaceID,
                token: arguments["token"]?.string, before: arguments["before"]?.int, count: arguments["count"]?.int ?? 128), timeout: 30) else { throw DaemonClientError.unexpectedResponse }
            return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        case "output.openMatch":
            guard let rawMatch = arguments["match"], let revision = arguments["revision"]?.int, revision >= 0 else {
                throw RemoteFailure(code: "badArguments", message: "A complete output match, epoch and revision are required")
            }
            let match = try JSONDecoder().decode(OutputSearchMatch.self, from: JSONEncoder().encode(rawMatch))
            guard case let .text(json) = try HarnessCLI.checkedRequest(client,
                .mobileHistoryMatch(match: match, epoch: try requiredString("epoch", arguments), revision: revision), timeout: 30) else { throw DaemonClientError.unexpectedResponse }
            return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        case "workspace.newSession":
            return try reply(.newSession(workspaceID: try requiredUUID("workspaceID", arguments), cwd: arguments["cwd"]?.string, name: arguments["name"]?.string))
        case "workspace.newTab":
            let response = try HarnessCLI.checkedRequest(client, .newTabInSession(sessionID: try requiredUUID("sessionID", arguments), cwd: arguments["cwd"]?.string ?? FileManager.default.homeDirectoryForCurrentUser.path), timeout: 10)
            guard case let .tabID(id) = response else { throw DaemonClientError.unexpectedResponse }
            if let name = arguments["name"]?.string, !name.isEmpty { _ = try HarnessCLI.checkedRequest(client, .renameTab(tabID: id, name: name)) }
            return .object(["tab": .string(id.uuidString)])
        case "workspace.renameTab": return try reply(.renameTab(tabID: try requiredUUID("tabID", arguments), name: try requiredString("name", arguments)))
        case "workspace.closeTab": return try reply(.closeTab(tabID: try requiredUUID("tabID", arguments)))
        case "workspace.pinSession": return try reply(.setSessionPersistent(sessionID: try requiredUUID("sessionID", arguments), persistent: arguments["persistent"]?.bool ?? true))
        case "workspace.moveTab": return try reply(.moveTab(tabID: try requiredUUID("tabID", arguments), toSessionID: try requiredUUID("sessionID", arguments), index: nil))
        case "workspace.create":
            return try reply(.newWorkspace(name: try requiredString("name", arguments)))
        case "workspace.rename":
            return try reply(.renameWorkspace(workspaceID: try requiredUUID("workspace", arguments), name: try requiredString("name", arguments)))
        case "workspace.close": return try reply(.closeWorkspace(id: try requiredUUID("workspace", arguments)))
        case "session.close": return try reply(.closeSession(sessionID: try requiredUUID("session", arguments)))
        case "session.rename": return try reply(.renameSession(sessionID: try requiredUUID("session", arguments), name: try requiredString("name", arguments)))
        case "workspace.closeSession": return try reply(.closeSession(sessionID: try requiredUUID("sessionID", arguments)))
        case "workspace.renameSession": return try reply(.renameSession(sessionID: try requiredUUID("sessionID", arguments), name: try requiredString("name", arguments)))
        case "workspace.moveSession": return try reply(.moveSession(sessionID: try requiredUUID("sessionID", arguments), toWorkspaceID: try requiredUUID("workspaceID", arguments)))
        case "workspace.reorderSession": return try reply(.reorderSession(workspaceID: try requiredUUID("workspaceID", arguments), sessionID: try requiredUUID("sessionID", arguments), toIndex: arguments["index"]?.int ?? 0))
        case "session.pin": return try reply(.setSessionPersistent(sessionID: try requiredUUID("session", arguments), persistent: arguments["persistent"]?.bool ?? true))
        case "tab.create":
            return try reply(.newTabInSession(sessionID: try requiredUUID("session", arguments), cwd: arguments["cwd"]?.string ?? FileManager.default.homeDirectoryForCurrentUser.path))
        case "tab.rename": return try reply(.renameTab(tabID: try requiredUUID("tab", arguments), name: try requiredString("name", arguments)))
        case "tab.close": return try reply(.closeTab(tabID: try requiredUUID("tab", arguments)))
        case "tab.pin": return try reply(.setTabPersistent(tabID: try requiredUUID("tab", arguments), persistent: arguments["persistent"]?.bool ?? true))
        case "tab.move":
            let session: UUID? = arguments["session"] == nil ? nil : try requiredUUID("session", arguments)
            return try reply(.moveTab(tabID: try requiredUUID("tab", arguments), toSessionID: session, index: arguments["index"]?.int))
        case "appearance.get":
            guard case let .snapshot(state) = try client.request(.getSnapshot) else { throw DaemonClientError.unexpectedResponse }
            return try value(MobileAppearance.resolve(themeName: state.themeName))
        default:
            guard HarnessAPI.methods.contains(where: { $0.name == request.method }) else {
                throw RemoteFailure(code: "unsupportedMethod", message: "Unknown companion method: \(request.method)")
            }
            let result = APIExecutor.call(method: request.method, arguments: try arguments.mapValues(apiArgument), client: client, environment: APIEnvironment(environment: [:]), exposure: .mobile)
            guard let json = result.json, result.message == nil else {
                throw RemoteFailure(code: "api.\(result.exitCode)", message: result.message ?? "The operation failed")
            }
            return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        }
    }

    private func attachPane(_ attach: HarnessRemoteProtocol.RemoteAttach) throws {
        try validateGeometry(cols: attach.cols, rows: attach.rows)
        guard try snapshot().panes.contains(where: { $0.address == attach.address }) else {
            throw RemoteFailure(code: "paneUnavailable", message: "This pane no longer exists at this address. Refresh your work.")
        }
        detachPane()
        let id = UUID()
        stateLock.lock(); generation = id; currentAttach = attach; stateLock.unlock()
        let request = AttachRequest(surfaceID: attach.address.surfaceID, label: "Harness Remote", readOnly: attach.readOnly,
            history: attach.fromSequence != nil, fromSequence: attach.fromSequence, epoch: attach.epoch, inputErrors: true, screenOnResync: true, checkpoint: true)
        let subscription = try client.attachStream(request, onAttached: { [weak self] reply in
            guard let self, self.isCurrent(id) else { return }
            self.emit(.attached(RemoteAttached(epoch: reply.epoch, resync: reply.resync, endSequence: reply.endSequence, screen: reply.screen, checkpoint: reply.checkpoint, inputErrors: reply.inputErrors == true)))
        }, onData: { [weak self] data, sequence in
            guard let self, self.isCurrent(id) else { return }
            self.emit(.output(RemoteOutput(surfaceID: attach.address.surfaceID, sequence: sequence, data: data)))
        }, onOwnership: { [weak self] owner in
            guard let self, self.isCurrent(id) else { return }
            let state = RemoteOwnership(surfaceID: owner.surfaceID, owner: owner.owner, responder: owner.responder ?? owner.owner,
                rows: owner.rows, cols: owner.cols, mode: owner.mode.rawValue, clientID: owner.clientID?.uuidString)
            self.emit(.ownership(state))
        }, onEnd: { [weak self] in
            guard let self, self.isCurrent(id) else { return }
            self.fail(RemoteFailure(code: "paneDisconnected", message: "This pane disconnected. Refresh and reconnect."))
        }, onError: { [weak self] message in
            guard let self, self.isCurrent(id) else { return }
            self.emit(.error(RemoteFailure(code: "attachFailed", message: message)))
        })
        subscription.setInputErrorHandler { [weak self] message in
            guard let self, self.isCurrent(id) else { return }
            self.emit(.error(RemoteFailure(code: "inputRejected", message: message)))
        }
        stateLock.lock(); pane = subscription; stateLock.unlock()
        if !attach.readOnly { subscription.resize(attach.address.surfaceID, rows: attach.rows, cols: attach.cols, takeOwnership: true) }
    }

    private func snapshot() throws -> RemoteSnapshot {
        guard case let .snapshot(state) = try client.request(.getSnapshot) else { throw DaemonClientError.unexpectedResponse }
        return RemoteSnapshot(revision: state.revision, themeName: state.themeName, workspaces: state.workspaces.map { workspace in
            RemoteWorkspace(id: workspace.id.uuidString, name: workspace.name, sessions: workspace.sessions.sorted { $0.sortOrder < $1.sortOrder }.map { session in
                let name = SessionDisplayName.title(of: session, in: workspace)
                return RemoteSession(id: session.id.uuidString, name: name, persistent: session.persistent, activeTabID: session.activeTabID?.uuidString,
                    tabs: session.tabs.sorted { $0.sortOrder < $1.sortOrder }.map { tab in
                        let panes = tab.rootPane.allLeaves().map { leaf in
                            let identity = PaneIdentity.of(leaf: leaf, in: tab)
                            return RemotePane(address: PaneAddress(workspaceID: workspace.id.uuidString, sessionID: session.id.uuidString,
                                tabID: tab.id.uuidString, paneID: leaf.id.uuidString, surfaceID: leaf.surfaceID.uuidString),
                                title: identity.program ?? tab.title, directory: identity.directory, program: identity.program,
                                agent: identity.agent?.commandToken, sessionName: name, tabTitle: tab.title)
                        }
                        return RemoteTab(id: tab.id.uuidString, title: tab.title, directory: tab.cwd, persistent: tab.persistent,
                            activePaneID: tab.activePaneID?.uuidString, layout: layout(tab.rootPane), panes: panes)
                    })
            })
        })
    }
    private func layout(_ node: PaneNode) -> RemotePaneLayout {
        switch node {
        case let .leaf(leaf): return .leaf(paneID: leaf.id.uuidString)
        case let .branch(direction, ratio, first, second): return .split(direction: direction.rawValue, ratio: ratio, first: layout(first), second: layout(second))
        }
    }
    private func attention() throws -> [RemoteAttention] {
        guard case let .text(json) = try client.request(.listAttention(capabilities: [DaemonStats.agentIdentities])) else { throw DaemonClientError.unexpectedResponse }
        return try JSONDecoder().decode([PaneAttention].self, from: Data(json.utf8)).map { row in
            RemoteAttention(address: PaneAddress(workspaceID: row.workspaceID.uuidString, sessionID: row.sessionID.uuidString,
                tabID: row.tabID.uuidString, paneID: row.paneID.uuidString, surfaceID: row.surfaceID.uuidString), sessionName: row.sessionName,
                tabTitle: row.tabTitle, rank: String(describing: row.activity.rank), message: row.activity.message,
                agent: row.activity.agent?.kind.commandToken, explicit: row.activity.mark?.fromRealReport == true || row.activity.notification != nil,
                unread: row.activity.unread, snoozedUntil: row.activity.snoozedUntil, updatedAt: row.activity.updatedAt)
        }
    }
    private func refresh() {
        guard !isFinished() else { return }
        do {
            let state = try snapshot()
            let activity = try attention()
            stateLock.lock()
            let changed = latestRevision != state.revision
            let attentionChanged = latestAttention != activity
            latestRevision = state.revision; latestAttention = activity
            stateLock.unlock()
            if changed { emit(.snapshot(state)) }
            if attentionChanged { emit(.attention(activity)) }
            publishAppearance(themeName: state.themeName)
        } catch { fail(RemoteFailure(code: "refreshFailed", message: error.localizedDescription)) }
    }
    private func publishAppearance(themeName: String) {
        do {
            let appearance = try MobileAppearance.resolve(themeName: themeName)
            stateLock.lock()
            let changed = latestAppearance != appearance
            latestAppearance = appearance
            stateLock.unlock()
            if changed { emit(.appearance(appearance)) }
        } catch { emit(.error(RemoteFailure(code: "appearanceUnavailable", message: error.localizedDescription))) }
    }
    private func startConfigurationWatch() {
        guard configurationTimer == nil else { return }
        // Snapshot pushes cover daemon state. Appearance overrides are local settings files,
        // so a bounded low-frequency metadata check covers macOS and headless Linux equally.
        // It never touches terminal output or runs on a pane channel.
        let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFinished() else { return }
            let themeFiles = (try? FileManager.default.contentsOfDirectory(at: HarnessPaths.themesDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            let urls = [HarnessPaths.settingsURL, HarnessPaths.themesDirectory] + themeFiles
                .filter { $0.pathExtension == "harnesstheme" }.sorted { $0.path < $1.path }
            let stamp = urls.map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
            }.joined(separator: "|") + (UserDefaults.standard.string(forKey: "AppleInterfaceStyle") ?? "Light")
            self.stateLock.lock()
            let changed = self.configurationStamp != stamp
            self.configurationStamp = stamp
            self.stateLock.unlock()
            if changed {
                do { self.publishAppearance(themeName: try self.snapshot().themeName) }
                catch { self.emit(.error(RemoteFailure(code: "appearanceUnavailable", message: error.localizedDescription))) }
            }
        }
        configurationTimer = timer
        timer.resume()
    }

    private func resolvePane(_ id: String?) throws -> RemotePane {
        guard let id, UUID(uuidString: id) != nil, let pane = try snapshot().panes.first(where: { $0.address.paneID == id || $0.address.surfaceID == id }) else {
            throw RemoteFailure(code: "paneUnavailable", message: "Provide the exact id of an existing pane")
        }
        return pane
    }
    private func value<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
    private func companionArgument(_ value: JSONValue) throws -> APIArgument {
        // Specialized contracts decode their payloads with the exact wire types.
        // The shared catalog checks top-level shapes; UInt64 output fingerprints
        // must not be narrowed through the general API's signed Int argument model.
        switch value {
        case .object: return .object([:])
        case .array: return .array([])
        case .null: throw CompanionAPIError.arguments
        default: return try apiArgument(value)
        }
    }
    private func apiArgument(_ value: JSONValue) throws -> APIArgument {
        switch value {
        case let .string(v): return .string(v)
        case let .int(v): return .int(v)
        case let .uint(v):
            guard let number = Int(exactly: v) else { throw RemoteFailure(code: "badArguments", message: "Integer exceeds this API's supported range") }
            return .int(number)
        case let .double(v): return .double(v)
        case let .bool(v): return .bool(v)
        case let .array(v): return .array(try v.map(apiArgument))
        case let .object(v): return .object(try v.mapValues(apiArgument))
        case .null: throw RemoteFailure(code: "badArguments", message: "Omit optional arguments instead of sending null")
        }
    }
    private func requiredString(_ key: String, _ args: [String: JSONValue]) throws -> String {
        guard let value = args[key]?.string, !value.isEmpty, value.utf8.count <= 16384 else { throw RemoteFailure(code: "badArguments", message: "\(key) is required") }
        return value
    }
    private func requiredUUID(_ key: String, _ args: [String: JSONValue]) throws -> UUID {
        guard let id = UUID(uuidString: try requiredString(key, args)) else { throw RemoteFailure(code: "badArguments", message: "\(key) must be a UUID") }
        return id
    }
    private func reply(_ request: IPCRequest) throws -> JSONValue {
        switch try HarnessCLI.checkedRequest(client, request, timeout: 10) {
        case .ok: return .object(["ok": .bool(true)])
        case let .workspaceID(id): return .object(["workspace": .string(id.uuidString)])
        case let .sessionID(id): return .object(["session": .string(id.uuidString)])
        case let .tabID(id): return .object(["tab": .string(id.uuidString)])
        case let .paneID(id): return .object(["pane": .string(id.uuidString)])
        default: throw DaemonClientError.unexpectedResponse
        }
    }
    private func validateGeometry(cols: UInt16, rows: UInt16) throws {
        guard cols > 0, rows > 0, cols <= 4096, rows <= 4096, Int(cols) * Int(rows) <= 1_048_576 else {
            throw RemoteFailure(code: "invalidGeometry", message: "Terminal dimensions exceed the supported size")
        }
    }
    private func detachPane() {
        stateLock.lock()
        generation = UUID(); let subscription = pane
        pane = nil; currentAttach = nil
        stateLock.unlock()
        subscription?.cancel()
    }
    private func closeAll() { detachPane(); configurationTimer?.cancel(); configurationTimer = nil; watcher?.cancel(); watcher = nil }
    private func isCurrent(_ id: UUID) -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return generation == id && !finished }
    private func isFinished() -> Bool { stateLock.lock(); defer { stateLock.unlock() }; return finished }
    private func emit(_ message: RemoteMessage) {
        do { try writer.write(message) }
        catch { stateLock.lock(); finished = true; stateLock.unlock() }
    }
    private func fail(_ failure: RemoteFailure) { emit(.error(failure)); stateLock.lock(); finished = true; stateLock.unlock() }
}

private final class MobileBridgeWriter: @unchecked Sendable {
    private let lock = NSLock()
    func write(_ message: RemoteMessage) throws {
        let data = try RemoteCodec.encode(message)
        lock.lock(); defer { lock.unlock() }
        let flags = fcntl(STDOUT_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { throw DaemonClientError.writeFailed }
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                guard DispatchTime.now().uptimeNanoseconds < deadline else { throw DaemonClientError.timeout }
                var ready = pollfd(fd: STDOUT_FILENO, events: Int16(POLLOUT), revents: 0)
                let result = poll(&ready, 1, 1000)
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw DaemonClientError.writeFailed }
                if result == 0 { continue }
                #if canImport(Darwin)
                let count = Darwin.write(STDOUT_FILENO, base.advanced(by: offset), raw.count - offset)
                #else
                let count = Glibc.write(STDOUT_FILENO, base.advanced(by: offset), raw.count - offset)
                #endif
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                else { throw DaemonClientError.writeFailed }
            }
        }
    }
}
