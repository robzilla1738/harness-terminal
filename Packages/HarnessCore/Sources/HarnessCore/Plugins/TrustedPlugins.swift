import Foundation

public struct PluginAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var detail: String?
    public var file: String
    public init(id: String, title: String, file: String, detail: String? = nil) {
        self.id = id; self.title = title; self.file = file; self.detail = detail
    }
}
public struct PluginManifest: Codable, Equatable, Sendable {
    public var format: Int
    public var id: String
    public var title: String
    public var actions: [PluginAction]
    public init(id: String, title: String, actions: [PluginAction]) { format = 1; self.id = id; self.title = title; self.actions = actions }
    public func validate() throws {
        func identifier(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 80 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0) }
        }
        func label(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
        guard format == 1, identifier(id), label(title), (1...32).contains(actions.count), Set(actions.map(\.id)).count == actions.count,
              actions.allSatisfy({ identifier($0.id) && label($0.title) && ($0.detail == nil || label($0.detail!)) && !$0.file.hasPrefix("/") && $0.file.hasSuffix(".lua") && $0.file.utf8.count <= 512 && !$0.file.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) }) else { throw PluginTrustError.invalid }
    }
}
/// The reviewed entry code is captured at approval. Discovery reads declarations;
/// neither the original files nor plugin code execute while building a palette.
public struct TrustedPlugin: Codable, Equatable, Sendable, Identifiable {
    public var id: String { manifest.id }
    public var manifest: PluginManifest
    public var sources: [String: String]
    public var reviewedPath: String
    public var approvedAt: Date
    public func validate() throws {
        try manifest.validate()
        guard Set(sources.keys) == Set(manifest.actions.map(\.file)), sources.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 << 10 }),
              sources.values.reduce(0, { $0 + $1.utf8.count }) <= 1 << 20 else { throw PluginTrustError.invalid }
    }
    public var review: String {
        "Plugin: " + manifest.title + " (" + id + ")\nSource: " + reviewedPath + "\nLua runs with your user privileges, including filesystem and process access. Approval captures the reviewed entry code. External modules and programs called by that code are subject to the same trust decision.\n\n" + manifest.actions.map {
            "Action: " + $0.title + " (" + $0.id + ")\nFile: " + $0.file + "\n" + (sources[$0.file] ?? "")
        }.joined(separator: "\n\n")
    }
}
public enum TrustedPlugins {
    public static var url: URL { HarnessPaths.applicationSupport.appendingPathComponent("trusted-plugins.json") }
    public static func prepare(_ manifestURL: URL) throws -> TrustedPlugin {
        guard let bytes = try PrivateFile.read(manifestURL, maximumBytes: 64 << 10) else { throw PluginTrustError.invalid }
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: bytes); try manifest.validate()
        let directory = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var sources: [String: String] = [:]
        for action in manifest.actions {
            let file = directory.appendingPathComponent(action.file).standardizedFileURL
            guard file.resolvingSymlinksInPath() == file, file.path.hasPrefix(directory.path + "/"),
                  let data = try PrivateFile.read(file, maximumBytes: 256 << 10), let source = String(data: data, encoding: .utf8) else { throw PluginTrustError.invalid }
            sources[action.file] = source
        }
        let result = TrustedPlugin(manifest: manifest, sources: sources, reviewedPath: manifestURL.path, approvedAt: .now)
        try result.validate(); return result
    }
    public static func load(from file: URL = url) throws -> [TrustedPlugin] {
        guard let bytes = try PrivateFile.read(file) else { return [] }
        let result = try JSONDecoder().decode([TrustedPlugin].self, from: bytes)
        guard result.count <= 64, Set(result.map(\.id)).count == result.count else { throw PluginTrustError.invalid }
        for plugin in result { try plugin.validate() }
        return result.sorted { $0.id < $1.id }
    }
    public static func approve(_ plugin: TrustedPlugin, at file: URL = url) throws {
        try plugin.validate()
        let prior = try PrivateFile.read(file)
        var plugins = try load(from: file); plugins.removeAll { $0.id == plugin.id }; plugins.append(plugin)
        guard plugins.count <= 64 else { throw PluginTrustError.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        _ = try PrivateFile.replace(file, data: encoder.encode(plugins), expected: prior)
    }
    public static func revoke(_ id: String, at file: URL = url) throws {
        let prior = try PrivateFile.read(file)
        var plugins = try load(from: file)
        guard plugins.contains(where: { $0.id == id }) else { throw PluginTrustError.missing }
        plugins.removeAll { $0.id == id }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        _ = try PrivateFile.replace(file, data: encoder.encode(plugins), expected: prior)
    }
    public static func source(plugin id: String, action actionID: String, from file: URL = url) throws -> String {
        guard let plugin = try load(from: file).first(where: { $0.id == id }), let action = plugin.manifest.actions.first(where: { $0.id == actionID }), let source = plugin.sources[action.file] else { throw PluginTrustError.missing }
        return source
    }
}
public enum PluginTrustError: Error, LocalizedError {
    case invalid, missing, localOnly
    public var errorDescription: String? {
        switch self {
        case .invalid: "Plugin declarations must use format 1, unique safe IDs, relative owned Lua files, and the bounded source budget (32 actions, 256 KiB per entry, 1 MiB per plugin). Symlinked files are refused."
        case .missing: "This plugin or action is not explicitly trusted. Review and approve its local manifest first."
        case .localOnly: "Plugin trust and execution are local. Remote, mobile and MCP requests cannot grant plugin trust."
        }
    }
}
