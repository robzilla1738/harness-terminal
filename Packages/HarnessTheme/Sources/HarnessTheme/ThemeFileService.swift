import Foundation

/// Reads and writes `.harnesstheme` files — the disk layer behind theme export, import,
/// and sharing. Pure Foundation (no AppKit), so it is unit-testable against a temp
/// directory. The app layer wires this to NSSavePanel/NSOpenPanel, drag-and-drop, and
/// the `application(_:open:)` document handler.
public struct ThemeFileService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Write a theme document to an explicit destination URL (e.g. from a save panel).
    public func export(_ document: ThemeDocument, to url: URL) throws {
        let data = try document.encoded()
        try data.write(to: url, options: .atomic)
    }

    /// Read and validate a theme document from a `.harnesstheme` file.
    public func importTheme(from url: URL) throws -> ThemeDocument {
        let data = try Data(contentsOf: url)
        return try ThemeDocument.decoded(from: data)
    }

    /// Install a theme into a directory (the user's themes folder), returning the file
    /// URL. The filename is derived from the theme name; existing files are overwritten
    /// so re-importing an updated theme replaces the old copy.
    @discardableResult
    public func install(_ document: ThemeDocument, into directory: URL) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Self.fileName(for: document.name))
        try export(document, to: url)
        return url
    }

    /// All valid theme documents in a directory (skips files that fail to parse rather
    /// than aborting the whole scan). Returns an empty array if the directory is missing.
    public func installedThemes(in directory: URL) throws -> [ThemeDocument] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return entries
            .filter { $0.pathExtension.lowercased() == ThemeDocument.fileExtension }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { try? importTheme(from: $0) }
    }

    /// A filesystem-safe `<name>.harnesstheme` filename. Path-hostile characters are
    /// replaced with `-`, runs collapsed, and empty names fall back to "theme".
    public static func fileName(for themeName: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
            .union(.controlCharacters)
        var sanitized = themeName
            .components(separatedBy: unsafe)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        if sanitized.isEmpty { sanitized = "theme" }
        return "\(sanitized).\(ThemeDocument.fileExtension)"
    }
}
