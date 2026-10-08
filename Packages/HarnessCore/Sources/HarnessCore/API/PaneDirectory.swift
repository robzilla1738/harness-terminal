import Foundation

/// One name from `pane.list_dir`. Paths belong to the daemon that listed them.
public struct PaneDirEntry: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var directory: Bool

    public init(name: String, path: String, directory: Bool) {
        self.name = name
        self.path = path
        self.directory = directory
    }
}

public struct PaneDirListing: Codable, Equatable, Sendable {
    public var root: String
    public var entries: [PaneDirEntry]

    public init(root: String, entries: [PaneDirEntry]) {
        self.root = root
        self.entries = entries
    }
}

/// Directory listing for the daemon that owns the pane. The root is the pane's
/// reported cwd unless the caller passes a path. Inserted paths are shell-quoted.
public enum PaneDirectory {
    public static func root(cwd: String, path: String?) -> String {
        let base = cwd.isEmpty ? "/" : cwd
        guard let path else { return base }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        if trimmed.hasPrefix("/") { return (trimmed as NSString).standardizingPath }
        let parent = base.hasSuffix("/") ? String(base.dropLast()) : base
        return ((parent as NSString).appendingPathComponent(trimmed) as NSString).standardizingPath
    }

    public static func list(root: String, fileManager: FileManager = .default) -> [PaneDirEntry] {
        let directory = (root as NSString).standardizingPath
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return [] }
        return names.sorted().map { name in
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            _ = fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            return PaneDirEntry(name: name, path: path, directory: isDirectory.boolValue)
        }
    }

    /// The listing the owning daemon returns. `cwd` is that daemon's pane cwd.
    public static func listing(cwd: String, path: String?, fileManager: FileManager = .default) -> PaneDirListing {
        let root = root(cwd: cwd, path: path)
        return PaneDirListing(root: root, entries: list(root: root, fileManager: fileManager))
    }

    public static func json(cwd: String, path: String?, fileManager: FileManager = .default) -> String {
        let listing = listing(cwd: cwd, path: path, fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(listing) else { return "{\"entries\":[],\"root\":\"\"}" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> PaneDirListing? {
        try? JSONDecoder().decode(PaneDirListing.self, from: Data(text.utf8))
    }

    /// Text the palette inserts. Every path is shell-quoted.
    public static func insertion(_ paths: [String]) -> String {
        paths.map(ShellQuoting.quote).joined(separator: " ")
    }

    /// `cd` of one directory. The path is shell-quoted.
    public static func goToDirectory(_ path: String) -> String {
        "cd \(ShellQuoting.quote(path))"
    }
}
