import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Copies/refreshes the installed `harness-cli` / `HarnessDaemon` binaries under the Harness
/// home (`bin/`). App updates replace the copies inside Harness.app but the LaunchAgent and the
/// user's PATH point at these installed ones — without a refresh they go stale and daemon-side
/// fixes silently never ship (issue #60).
///
/// Replacement stages a verified fresh inode and atomically renames it into place.
/// A running executable keeps its inode, and failed copies leave the installed file intact.
public enum BinaryRefresher {
    public static var binDirectory: URL {
        HarnessPaths.applicationSupport.appendingPathComponent("bin", isDirectory: true)
    }

    public static var installedCLIPath: URL {
        binDirectory.appendingPathComponent("harness-cli")
    }

    public static var installedSessionHostPath: URL { binDirectory.appendingPathComponent("HarnessSessionHost") }

    public static var installedDaemonPath: URL {
        binDirectory.appendingPathComponent("HarnessDaemon")
    }
    /// Validate an installer-owned helper alias before uninstall removes its bundle.
    public static func ownedHelperBundle(forInstalledExecutable url: URL) throws -> URL? {
        #if os(macOS)
        return try MacOSHelperInstaller.ownedBundle(for: url)
        #else
        return nil
        #endif
    }
    /// Serialize complete helper removal with concurrent bundle installation.
    public static func withInstalledToolsLock<T>(_ work: () throws -> T) throws -> T {
        #if os(macOS)
        return try MacOSHelperInstaller.withInstallationLock(directory: binDirectory, work)
        #else
        return try work()
        #endif
    }

    /// Copy `source` → `destination` atomically and mark it executable. Also used for
    /// the install-in-place case (source == destination), which only needs the chmod.
    public static func copyExecutable(from source: URL, to destination: URL) throws {
        #if os(macOS)
        if try MacOSHelperInstaller.installIfBundled(source: source, destination: destination) { return }
        #endif
        let source = source.resolvingSymlinksInPath()
        guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        if source.standardizedFileURL.path != destination.standardizedFileURL.path {
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: source, to: staged)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            guard FileManager.default.contentsEqual(atPath: source.path, andPath: staged.path) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let handle = try FileHandle(forWritingTo: staged)
            defer { try? handle.close() }
            try handle.synchronize()
            guard rename(staged.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
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
              FileManager.default.fileExists(atPath: destination.path)
        else { return false }
        #if os(macOS)
        if let required = try MacOSHelperInstaller.bundledRefreshRequired(source: source, destination: destination) {
            guard required else { return false }
            try copyExecutable(from: source, to: destination)
            return true
        }
        #endif
        guard !FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path) else { return false }
        try copyExecutable(from: source, to: destination)
        return true
    }
}
