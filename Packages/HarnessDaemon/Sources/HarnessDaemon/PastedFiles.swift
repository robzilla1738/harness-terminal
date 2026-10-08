import Foundation
import HarnessCore

/// Files pasted into a pane from another Mac: written owner-only under the daemon's runtime
/// directory and swept after a day, like the app's own pasted images.
enum PastedFiles {
    struct Failure: Error { var message: String }

    /// Leaves room under the 16 MiB frame cap for base64.
    static let maxBytes = 11 * 1024 * 1024

    static func write(_ data: Data, named name: String, in directory: URL = HarnessPaths.pastedImagesDirectory) -> Result<String, Failure> {
        guard data.count <= maxBytes else { return .failure(Failure(message: "file is larger than \(maxBytes / 1024 / 1024) MB")) }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        sweep(directory)
        let base = (name as NSString).lastPathComponent
            .components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "-")
        let safe = base.isEmpty || base.hasPrefix(".") ? "pasted" : base
        let url = directory.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safe)")
        guard fm.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return .failure(Failure(message: "could not write \(url.path)"))
        }
        return .success(url.path)
    }

    private static func sweep(_ directory: URL, olderThan age: TimeInterval = 24 * 60 * 60) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
