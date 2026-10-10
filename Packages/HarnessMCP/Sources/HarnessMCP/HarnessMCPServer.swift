import Foundation
import HarnessCore
import MCP

/// The official SDK and protocol types remain confined to this integration target.
public enum HarnessMCPServer {
    public static let approvedReadMethods: Set<String> = [
        "server.version", "session.list", "session.view", "pane.capture", "pane.process", "pane.resources",
        "pane.pwd", "pane.list_dir", "pane.title", "pane.size", "pane.program_status", "pane.view",
        "agent.list", "agent.session", "usage.summary", "digest.get", "attention.list",
    ]
    public static let approvedWriteMethods: Set<String> = ["pane.write", "pane.send_key", "pane.focus", "attention.read", "attention.snooze"]
    public static func run(endpoint: Endpoint = .localControlSocket, allowWrite: Bool = false, callerSurface: String? = nil) async throws {
        let integration = MCPIntegration(endpoint: endpoint, allowWrite: allowWrite, callerSurface: callerSurface)
        try await integration.run()
    }
}
private actor MCPIntegration {
    let endpoint: Endpoint
    let allowWrite: Bool
    let callerSurface: String?
    private var active = 0
    init(endpoint: Endpoint, allowWrite: Bool, callerSurface: String?) {
        self.endpoint = endpoint; self.allowWrite = allowWrite; self.callerSurface = callerSurface
    }
    private var methods: [APIMethod] {
        HarnessAPI.methods.filter {
            $0.access.exposures.contains(.mcp) && (HarnessMCPServer.approvedReadMethods.contains($0.name) || (allowWrite && HarnessMCPServer.approvedWriteMethods.contains($0.name)))
        }
    }
    func run() async throws {
        let server = Server(name: "Harness", version: HarnessVersion.short,
            capabilities: .init(resources: .init(subscribe: false, listChanged: false), tools: .init(listChanged: false)), configuration: .strict)
        await server.withMethodHandler(ListTools.self) { [self] _ in try await listTools() }
        await server.withMethodHandler(CallTool.self) { [self] params in try await call(params) }
        await server.withMethodHandler(ListResources.self) { [self] params in try await listResources(cursor: params.cursor) }
        await server.withMethodHandler(ReadResource.self) { [self] params in try await readResource(params.uri) }
        try await server.start(transport: BoundedStdioTransport())
        await server.waitUntilCompleted()
        await server.stop()
    }
    private func listTools() throws -> ListTools.Result {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        return .init(tools: try methods.map { method in
            Tool(name: method.name, description: method.summary,
                inputSchema: try decoder.decode(Value.self, from: encoder.encode(method.parameters)),
                annotations: .init(readOnlyHint: method.access.effect == .read, destructiveHint: method.access.effect == .write, openWorldHint: false))
        })
    }
    private func bounded<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        guard active < 8 else { throw MCPError.internalError("Harness has eight requests in progress; retry after one completes") }
        try Task.checkCancellation(); active += 1; defer { active -= 1 }
        let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try operation() }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation(); return value
    }
    private func call(_ params: CallTool.Parameters) async throws -> CallTool.Result {
        guard methods.contains(where: { $0.name == params.name }) else {
            return failure("Tool is not approved in this server. Write tools require --allow-write; local administration is never exposed.", code: APIExit.badArguments.rawValue)
        }
        let arguments: [String: APIArgument]
        do {
            let encoded = try JSONEncoder().encode(params.arguments ?? [:])
            guard encoded.count <= 128 * 1024 else { return failure("Tool arguments exceed 128 KiB", code: APIExit.badArguments.rawValue) }
            arguments = try HarnessAPI.arguments(from: String(decoding: encoded, as: UTF8.self)).get()
        } catch { return failure("Tool arguments must match the published schema", code: APIExit.badArguments.rawValue) }
        let endpoint = endpoint, allowWrite = allowWrite, callerSurface = callerSurface
        let result = try await bounded {
            APIExecutor.call(method: params.name, arguments: arguments, client: DaemonClient(endpoint: endpoint),
                environment: APIEnvironment(environment: callerSurface.map { ["HARNESS_SURFACE": $0] } ?? [:]), exposure: .mcp, allowWrite: allowWrite,
                protectedSurfaceID: callerSurface, mutationAudit: { method, surface in
                    // Metadata only. Arguments, pasted text, key tokens, and secrets never
                    // enter the mutation audit or stdout's protocol stream.
                    let metadata = ["event": "mcp-mutation", "method": method, "surface": surface ?? "", "at": Date().formatted(.iso8601)]
                    if let data = try? JSONEncoder().encode(metadata) { try? FileHandle.standardError.write(contentsOf: data + Data([10])) }
                })
        }
        guard let json = result.json else { return failure(result.message ?? "Harness could not complete this request", code: Int(result.exitCode)) }
        guard json.utf8.count <= 2 << 20 else { return failure("Result exceeds 2 MiB; narrow the request or paginate its history", code: APIExit.failed.rawValue) }
        let value = try JSONDecoder().decode(Value.self, from: Data(json.utf8))
        return .init(content: [.text(text: json, annotations: nil, _meta: nil)], structuredContent: Optional<Value>.some(value), isError: false)
    }
    private func failure(_ message: String, code: Int) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], structuredContent: .object(["error": .object(["message": .string(message), "code": .int(code)])]), isError: true)
    }
    private func listResources(cursor: String?) async throws -> ListResources.Result {
        let endpoint = endpoint
        return try await bounded {
            guard case let .snapshot(snapshot) = try DaemonClient(endpoint: endpoint).requestForCurrentClient(.getSnapshot) else { throw MCPError.internalError("Harness did not return its layout") }
            return try MCPResourcePageBuilder.page(snapshot, cursor: cursor)
        }
    }
    private func readResource(_ uri: String) async throws -> ReadResource.Result {
        guard let url = URL(string: uri), url.scheme == "harness", url.host == "pane", url.query == nil, url.fragment == nil else { throw MCPError.invalidParams("Expected harness://pane/<surface UUID>/screen") }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, let surface = UUID(uuidString: String(parts[0])), parts[1] == "screen" else { throw MCPError.invalidParams("Pane screen resource identity is invalid") }
        let endpoint = endpoint
        let text = try await bounded {
            let client = DaemonClient(endpoint: endpoint)
            guard case let .text(text) = try client.request(.captureFormatted(surfaceID: surface.uuidString, format: "text", trim: false, unwrap: false, screen: true)) else { throw MCPError.internalError("Pane screen is unavailable; it may have closed") }
            guard text.utf8.count <= 256 * 1024 else { throw MCPError.invalidParams("The pane screen exceeds the 256 KiB resource limit. Use pane.capture for an explicit bounded capture.") }
            return text
        }
        return .init(contents: [.text(text, uri: uri, mimeType: "text/plain")])
    }
}

/// Identity cursors continue across metadata-only revisions. Re-list from the
/// beginning after layout changes; terminal resources are never silently capped.
internal enum MCPResourcePageBuilder {
    static func page(_ snapshot: SessionSnapshot, cursor: String?) throws -> ListResources.Result {
        let after: String?
        if let cursor {
            guard cursor.hasPrefix("pane-v1:"), let id = UUID(uuidString: String(cursor.dropFirst(8))) else { throw MCPError.invalidParams("Invalid pane resource cursor. Restart resources/list without a cursor.") }
            after = id.uuidString
        } else { after = nil }
        var byID: [String: Resource] = [:]
        for tab in snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs) {
            for leaf in tab.rootPane.allLeaves() where leaf.paneContent.isTerminal {
                let id = leaf.surfaceID.uuidString
                if after.map({ id <= $0 }) == true { continue }
                byID[id] = Resource(name: tab.title + " screen", uri: "harness://pane/" + id + "/screen", description: "Current terminal screen, without input or transcript history", mimeType: "text/plain")
            }
        }
        let keys = byID.keys.sorted(), page = Array(keys.prefix(500))
        return .init(resources: page.compactMap { byID[$0] }, nextCursor: keys.count > page.count ? page.last.map { "pane-v1:" + $0 } : nil)
    }
}
