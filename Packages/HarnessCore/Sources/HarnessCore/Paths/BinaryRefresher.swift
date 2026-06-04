import Foundation

/// Copies/refreshes the installed `harness-cli` / `HarnessDaemon` binaries under the Harness
/// home (`bin/`). App updates replace the copies inside Harness.app but the LaunchAgent and the
/// user's PATH point at these installed ones — without a refresh they go stale and daemon-side
/// fixes silently never ship (issue #60).
///
/// Replacement is remove-then-copy, never overwrite-in-place: the kernel caches code signatures
/// by vnode, so rewriting the same inode gets the next daemon launch killed with
/// `OS_REASON_CODESIGNING`. Deleting first puts the copy on a fresh inode.
public enum BinaryRefresher {
    public static var binDirectory: URL {
        HarnessPaths.applicationSupport.appendingPathComponent("bin", isDirectory: true)
    }

    public static var installedCLIPath: URL {
        binDirectory.appendingPathComponent("harness-cli")
    }

    public static var installedDaemonPath: URL {
        binDirectory.appendingPathComponent("HarnessDaemon")
    }

    /// Copy `source` → `destination` (remove-then-copy) and mark it executable. Also used for
    /// the install-in-place case (source == destination), which only needs the chmod.
    public static func copyExecutable(from source: URL, to destination: URL) throws {
        if source.standardizedFileURL.path != destination.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    /// Refresh `destination` from `source` only when `destination` already exists (only update
    /// what an installer previously put there — never create installs as a side effect),
    /// `source` exists, and the bytes differ. Returns true iff a copy happened.
    @discardableResult
    public static func refreshIfChanged(source: URL?, destination: URL) throws -> Bool {
        guard let source,
              FileManager.default.fileExists(atPath: source.path),
              FileManager.default.fileExists(atPath: destination.path),
              !FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path)
        else { return false }
        try copyExecutable(from: source, to: destination)
        return true
    }
}
