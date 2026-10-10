import Foundation
import TOML
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum MCPClientConfiguration: String, CaseIterable, Sendable { case claude, codex, cursor }
public struct MCPInstallation: Sendable {
    public var path: URL
    public var proposed: String
    public var backup: URL?
    public var changed: Bool
}
public enum MCPInstaller {
    private struct Entry: Codable, Equatable { var command: String?; var args: [String]? }
    private struct Probe: Decodable { var mcp_servers: [String: Entry]? }
    private struct ManagedBlock: Decodable {
        private struct Key: CodingKey { var stringValue: String; var intValue: Int? { nil }; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
        init(from decoder: Decoder) throws {
            let root = try decoder.container(keyedBy: Key.self)
            guard Set(root.allKeys.map(\.stringValue)) == ["mcp_servers"], let serversKey = Key(stringValue: "mcp_servers") else { throw MCPInstallError.conflict }
            let servers = try root.nestedContainer(keyedBy: Key.self, forKey: serversKey)
            guard Set(servers.allKeys.map(\.stringValue)) == ["harness"], let harnessKey = Key(stringValue: "harness") else { throw MCPInstallError.conflict }
            let entry = try servers.nestedContainer(keyedBy: Key.self, forKey: harnessKey)
            guard Set(entry.allKeys.map(\.stringValue)) == ["command", "args"] else { throw MCPInstallError.conflict }
        }
    }
    private struct Config: Encodable { var mcp_servers: [String: Entry] }
    public static func configuration(client: MCPClientConfiguration, executable: String, allowWrite: Bool = false) throws -> String {
        let entry = Entry(command: executable, args: ["mcp"] + (allowWrite ? ["--allow-write"] : []))
        if client == .codex { return String(decoding: try TOMLEncoder().encode(Config(mcp_servers: ["harness": entry])), as: UTF8.self) }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["mcpServers": ["harness": ["command": executable, "args": entry.args!]]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    public static func install(client: MCPClientConfiguration, executable: String, allowWrite: Bool = false, write: Bool = false,
                               home: URL = FileManager.default.homeDirectoryForCurrentUser, path: URL? = nil) throws -> MCPInstallation {
        let destination = path ?? home.appendingPathComponent(client == .codex ? ".codex/config.toml" : client == .cursor ? ".cursor/mcp.json" : ".claude.json")
        let proposed = try configuration(client: client, executable: executable, allowWrite: allowWrite)
        // Default/dry run reads and writes no configuration, creates no directory or backup.
        guard write else { return MCPInstallation(path: destination, proposed: proposed, backup: nil, changed: false) }
        let old = try readOwned(destination)
        let result: Data
        if client == .codex {
            let source = old.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let probe = try TOMLDecoder().decode(Probe.self, from: source)
            let expected = Entry(command: executable, args: ["mcp"] + (allowWrite ? ["--allow-write"] : []))
            if let existing = probe.mcp_servers?["harness"] {
                if existing == expected { return MCPInstallation(path: destination, proposed: proposed, backup: nil, changed: false) }
                guard existing.command == executable, existing.args == ["mcp"] || existing.args == ["mcp", "--allow-write"] else { throw MCPInstallError.conflict }
                // Replace only our managed section. Source-aware parsing validates the
                // candidate; unrelated TOML and comments remain byte-for-byte intact.
                let begin = "# Harness managed MCP configuration begin\n", end = "# Harness managed MCP configuration end\n"
                guard let start = source.range(of: begin), let finish = source.range(of: end, range: start.upperBound..<source.endIndex) else { throw MCPInstallError.conflict }
                _ = try TOMLDecoder().decode(ManagedBlock.self, from: String(source[start.upperBound..<finish.lowerBound]))
                let updated = String(source[..<start.lowerBound]) + begin + proposed + "\n" + end + String(source[finish.upperBound...])
                _ = try TOMLDecoder().decode(Probe.self, from: updated); result = Data(updated.utf8)
            } else {
                let updated = source + (source.hasSuffix("\n") || source.isEmpty ? "" : "\n") + "\n# Harness managed MCP configuration begin\n" + proposed + "\n# Harness managed MCP configuration end\n"
                _ = try TOMLDecoder().decode(Probe.self, from: updated); result = Data(updated.utf8)
            }
        } else {
            var object: [String: Any] = [:]
            if let old {
                guard let parsed = try JSONSerialization.jsonObject(with: old) as? [String: Any] else { throw MCPInstallError.format }
                object = parsed
            }
            if let existing = object["mcpServers"], !(existing is [String: Any]) { throw MCPInstallError.format }
            var servers = object["mcpServers"] as? [String: Any] ?? [:]
            if let value = servers["harness"] {
                guard let entry = value as? [String: Any], entry["command"] as? String == executable,
                      let args = entry["args"] as? [String], args == ["mcp"] || args == ["mcp", "--allow-write"] else { throw MCPInstallError.conflict }
            }
            servers["harness"] = ["command": executable, "args": ["mcp"] + (allowWrite ? ["--allow-write"] : [])]
            object["mcpServers"] = servers
            result = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data([10])
        }
        if result == old { return MCPInstallation(path: destination, proposed: proposed, backup: nil, changed: false) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backup: URL?
        if let old {
            let url = destination.appendingPathExtension("harness-backup-" + UUID().uuidString)
            try atomicWrite(old, to: url); backup = url
        }
        // Refuse concurrent edits rather than replacing newer user configuration.
        guard try readOwned(destination) == old else { throw MCPInstallError.changed }
        try atomicWrite(result, to: destination)
        return MCPInstallation(path: destination, proposed: proposed, backup: backup, changed: true)
    }
    private static func readOwned(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw MCPInstallError.storage }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1 << 20 else { throw MCPInstallError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data(); guard data.count <= 1 << 20 else { throw MCPInstallError.storage }; return data
    }
    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let stage = url.deletingLastPathComponent().appendingPathComponent(".harness-mcp-" + UUID().uuidString)
        let fd = open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw MCPInstallError.storage }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: stage) }
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard rename(stage.path, url.path) == 0 else { throw MCPInstallError.storage }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }
}
private enum MCPInstallError: Error, LocalizedError {
    case format, conflict, storage, changed
    var errorDescription: String? {
        switch self {
        case .format: "The existing MCP configuration has an invalid format; it was preserved."
        case .conflict: "An existing Harness MCP entry is not managed by this installer. Use the printed configuration to review and merge it explicitly."
        case .storage: "The MCP configuration must be an owned regular file smaller than 1 MiB."
        case .changed: "The configuration changed during installation; retry after reviewing the latest file."
        }
    }
}
