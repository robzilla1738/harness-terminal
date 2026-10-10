import Foundation

/// Companion-only wire contracts use the same effect/exposure/capability metadata
/// as public APIs. They do not automatically become Lua or MCP tools.
public enum CompanionAPICatalog {
    public static let methods: [APIMethod] = [
        read("snapshot.get", "Read the companion projection of the current layout", [:]),
        read("snapshot.watch", "Watch layout, attention and appearance changes", [:]),
        read("attention.get", "Read panes requiring attention", [:], [DaemonStats.paneAttention]),
        read("appearance.get", "Read host appearance", [:]),
        read("pane.history", "Page retained styled terminal history", ["pane": "string", "token": "string", "before": "integer", "count": "integer"]),
        read("output.openMatch", "Open a validated terminal-output match", ["match": "object", "epoch": "string", "revision": "integer"], [DaemonStats.outputSearch], required: ["match", "epoch", "revision"]),
        write("file.upload", "Write a bounded private temporary file", ["name": "string", "data": "string"], required: ["name", "data"]),
        write("workspace.newSession", "Create a session in an exact workspace", ["workspaceID": "string", "cwd": "string", "name": "string"], required: ["workspaceID"]),
        write("workspace.newTab", "Create a tab in an exact session", ["sessionID": "string", "cwd": "string", "name": "string"], required: ["sessionID"]),
        write("workspace.renameTab", "Rename an exact tab", ["tabID": "string", "name": "string"], required: ["tabID", "name"]),
        write("workspace.closeTab", "Close a tab and its unshared programs", ["tabID": "string"], required: ["tabID"]),
        write("workspace.pinSession", "Set session persistence", ["sessionID": "string", "persistent": "boolean"], required: ["sessionID"]),
        write("workspace.moveTab", "Move an exact tab to a session", ["tabID": "string", "sessionID": "string"], required: ["tabID", "sessionID"]),
        write("workspace.create", "Create a workspace", ["name": "string"], required: ["name"]),
        write("workspace.rename", "Rename a workspace", ["workspace": "string", "name": "string"], required: ["workspace", "name"]),
        write("workspace.close", "Close a workspace and its unshared programs", ["workspace": "string"], required: ["workspace"]),
        write("session.close", "Close a session and its unshared programs", ["session": "string"], required: ["session"]),
        write("session.rename", "Rename a session", ["session": "string", "name": "string"], required: ["session", "name"]),
        write("workspace.closeSession", "Close an exact session", ["sessionID": "string"], required: ["sessionID"]),
        write("workspace.renameSession", "Rename an exact session", ["sessionID": "string", "name": "string"], required: ["sessionID", "name"]),
        write("workspace.moveSession", "Move a session to a workspace", ["sessionID": "string", "workspaceID": "string"], required: ["sessionID", "workspaceID"]),
        write("workspace.reorderSession", "Reorder a workspace's session", ["workspaceID": "string", "sessionID": "string", "index": "integer"], required: ["workspaceID", "sessionID"]),
        write("session.pin", "Set session persistence", ["session": "string", "persistent": "boolean"], required: ["session"]),
        write("tab.create", "Create a tab", ["session": "string", "cwd": "string"], required: ["session"]),
        write("tab.rename", "Rename a tab", ["tab": "string", "name": "string"], required: ["tab", "name"]),
        write("tab.close", "Close a tab and its unshared programs", ["tab": "string"], required: ["tab"]),
        write("tab.pin", "Set tab persistence", ["tab": "string", "persistent": "boolean"], required: ["tab"]),
        write("tab.move", "Move or reorder a tab", ["tab": "string", "session": "string", "index": "integer"], required: ["tab"]),
        write("device.installKey", "Install a local trusted SSH device key", ["publicKey": "string"], required: ["publicKey"], exposures: [.cli]),
        write("device.removeKey", "Remove a local trusted SSH device key", ["publicKey": "string"], required: ["publicKey"], exposures: [.cli]),
    ]
    public static func method(named name: String) -> APIMethod? { methods.first { $0.name == name } }
    public static func validate(name: String, arguments: [String: APIArgument], exposure: APIExposure, capabilities: Set<String>, allowWrite: Bool = true) throws {
        guard let method = method(named: name), method.access.exposures.contains(exposure),
              allowWrite || method.access.effect == .read else { throw CompanionAPIError.denied }
        guard method.access.capabilities.isSubset(of: capabilities) else { throw CompanionAPIError.capability }
        guard Set(arguments.keys).isSubset(of: Set(method.parameters.properties?.keys.map { $0 } ?? [])),
              (method.parameters.required ?? []).allSatisfy({ arguments[$0] != nil }) else { throw CompanionAPIError.arguments }
        for (key, value) in arguments {
            let type: String
            switch value { case .string: type = "string"; case .int: type = "integer"; case .bool: type = "boolean"; case .object: type = "object"; case .array: type = "array"; case .double: type = "number" }
            guard method.parameters.properties?[key]?.type == type else { throw CompanionAPIError.arguments }
        }
    }
    private static func read(_ name: String, _ summary: String, _ fields: [String: String], _ capabilities: Set<String> = [], required: [String] = []) -> APIMethod {
        definition(name, summary, fields, required: required, effect: .read, exposures: [.mobile], capabilities: capabilities)
    }
    private static func write(_ name: String, _ summary: String, _ fields: [String: String], required: [String], exposures: Set<APIExposure> = [.mobile]) -> APIMethod {
        definition(name, summary, fields, required: required, effect: .write, exposures: exposures, capabilities: [])
    }
    private static func definition(_ name: String, _ summary: String, _ fields: [String: String], required: [String], effect: APIEffect, exposures: Set<APIExposure>, capabilities: Set<String>) -> APIMethod {
        APIMethod(name: name, summary: summary, parameters: APIJSONSchema(type: "object", properties: fields.mapValues { APIJSONSchema(type: $0) }, required: required, additionalProperties: false),
            result: APIJSONSchema(type: "object"), access: APIAccess(effect: effect, exposures: exposures, capabilities: capabilities.union([DaemonStats.mobileCompanion])))
    }
}
public enum CompanionAPIError: Error, LocalizedError {
    case denied, capability, arguments
    public var errorDescription: String? {
        switch self {
        case .denied: "This operation is not approved through the companion. Device trust and credential administration require the local host."
        case .capability: "The host daemon does not support this companion operation. Adopt a compatible update while preserving shells."
        case .arguments: "Companion arguments do not match the published method schema."
        }
    }
}
