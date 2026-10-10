import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum HistoryMigration {
    /// Read the old adjacent key only to convert old caches into the new protection
    /// boundary. Originals and that key remain until every conversion is verified.
    static func checkpoints(directory: URL, legacyKeyURL: URL, protection: HistoryProtection) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return nil }
        let legacy = files.filter { $0.pathExtension == "park" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
        // Remove only private stages with the exact migration naming convention.
        for stage in files where stage.lastPathComponent.hasPrefix(".") && stage.lastPathComponent.contains(".park.encrypt-") {
            let parts = stage.lastPathComponent.dropFirst().components(separatedBy: ".park.encrypt-")
            guard parts.count == 2, UUID(uuidString: parts[0]) != nil, UUID(uuidString: parts[1]) != nil,
                  let bytes = try? privateRead(stage, maximum: 24 << 20), bytes.count < 8 || HistoryProtection.isProtectedRecord(bytes) else { continue }
            try? FileManager.default.removeItem(at: stage)
        }
        guard !legacy.isEmpty else {
            if (try? privateRead(legacyKeyURL, maximum: 32)) != nil { try? FileManager.default.removeItem(at: legacyKeyURL) }
            return nil
        }
        guard protection.kind != .keyUnavailable else { return "Checkpoint migration is waiting for the history key; original files remain private and programs continue." }
        var failures = 0
        let key = try? privateRead(legacyKeyURL, maximum: 32)
        for url in legacy {
            do {
                let sealed = try privateRead(url, maximum: 24 << 20)
                if HistoryProtection.isProtectedRecord(sealed) {
                    let opened = try protection.open(sealed, identity: "checkpoint:" + url.deletingPathExtension().lastPathComponent)
                    guard let frame = ScreenFrame.decode(opened.data), frame.sequence == opened.sequence else { throw HistoryProtectionError.corruptRecord }
                    continue
                }
                guard let key, key.count == 32, let plain = SnapshotCipher.open(sealed: sealed, key: key), let frame = ScreenFrame.decode(plain) else { throw HistoryProtectionError.corruptRecord }
                let identity = "checkpoint:" + url.deletingPathExtension().lastPathComponent
                let protected = try protection.seal(plain, identity: identity, sequence: frame.sequence)
                let stage = directory.appendingPathComponent(".\(url.lastPathComponent).encrypt-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: stage) }
                let fd = open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try handle.write(contentsOf: protected); try handle.synchronize(); try handle.close()
                let verified = try protection.open(privateRead(stage, maximum: 24 << 20), identity: identity, sequence: frame.sequence)
                guard verified == plain, rename(stage.path, url.path) == 0 else { throw HistoryProtectionError.corruptRecord }
            } catch { failures += 1 }
        }
        let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 { _ = fsync(fd); close(fd) }
        if failures == 0 { try? FileManager.default.removeItem(at: legacyKeyURL) }
        return failures == 0 ? nil : "\(failures) legacy checkpoints could not be authenticated or converted. Originals were retained for recovery; running programs continue."
    }
    private static func privateRead(_ url: URL, maximum: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true); defer { try? handle.close() }
        var information = stat()
        guard fstat(fd, &information) == 0, information.st_uid == getuid(), information.st_mode & S_IFMT == S_IFREG,
              information.st_size >= 0, information.st_size <= maximum, fchmod(fd, 0o600) == 0 else { throw POSIXError(.EPERM) }
        guard let bytes = try handle.read(upToCount: maximum + 1), bytes.count <= maximum else { throw HistoryProtectionError.recordTooLarge }
        return bytes
    }
}
