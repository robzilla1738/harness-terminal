#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessRemoteProtocol

/// Adds only a validated plain Ed25519 public key. No shell, options, or caller comments
/// are evaluated; unrelated authorized_keys lines stay byte-for-byte intact.
enum MobileDeviceKeys {
    static func normalized(_ source: String) throws -> String {
        guard source.utf8.count <= 2048, !source.contains(where: \.isNewline) else { throw invalidKey() }
        let parts = source.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "ssh-ed25519", let blob = Data(base64Encoded: String(parts[1])), blob.count == 51 else { throw invalidKey() }
        let expectedPrefix = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32])
        guard blob.prefix(expectedPrefix.count) == expectedPrefix else { throw invalidKey() }
        let encoded = blob.base64EncodedString()
        return "ssh-ed25519 \(encoded) harness-mobile-\(encoded.suffix(12).filter { $0.isLetter || $0.isNumber })"
    }

    static func install(_ source: String) throws {
        let line = try normalized(source)
        try withDirectory(create: true) { directoryFD in
            let existing = try readAuthorizedKeys(directoryFD)
            let fields = line.split(separator: " ")
            let text = String(decoding: existing, as: UTF8.self)
            if text.split(whereSeparator: \.isNewline).contains(where: { row in
                let parts = row.split(whereSeparator: \.isWhitespace)
                return parts.count >= 2 && parts[0] == fields[0] && parts[1] == fields[1]
            }) { return }
            var replacement = existing
            if !existing.isEmpty, existing.last != 10 { replacement.append(10) }
            replacement.append(Data((line + "\n").utf8))
            try replaceAuthorizedKeys(replacement, directoryFD)
        }
    }

    /// Roll back only the exact line installed by Harness. A matching key previously
    /// installed by the user has a different line/comment and is deliberately preserved.
    static func remove(_ source: String) throws -> Bool {
        let line = try normalized(source)
        var didRemove = false
        try withDirectory(create: false) { directoryFD in
            let existing = try readAuthorizedKeys(directoryFD)
            let expected = Data(line.utf8)
            var replacement = Data(), removed = false
            var start = existing.startIndex
            while start < existing.endIndex {
                let newline = existing[start...].firstIndex(of: 10)
                let end = newline ?? existing.endIndex
                if existing[start..<end] == expected { removed = true }
                else { replacement.append(existing[start..<end]); if newline != nil { replacement.append(10) } }
                start = newline.map { $0 + 1 } ?? existing.endIndex
            }
            if removed { try replaceAuthorizedKeys(replacement, directoryFD); didRemove = true }
        }
        return didRemove
    }

    private static func withDirectory(create: Bool, _ body: (Int32) throws -> Void) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            if !create { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw fileFailure("The SSH directory must be a real directory owned by this account") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), fchmod(fd, 0o700) == 0 else { throw fileFailure("Could not secure the SSH directory") }
        // A stable sibling lock survives atomic authorized_keys replacement, coordinating
        // simultaneous mobile setup/rollback without locking an obsolete inode.
        let lockFD = openat(fd, ".harness-mobile.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw fileFailure("Could not open the device-key lock") }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(), (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockf(lockFD, F_TLOCK, 0) == 0 else { throw fileFailure("Another device-key change is in progress") }
        defer { _ = lockf(lockFD, F_ULOCK, 0) }
        try body(fd)
    }

    private static func readAuthorizedKeys(_ directoryFD: Int32) throws -> Data {
        let fd = openat(directoryFD, "authorized_keys", O_RDONLY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return Data() }
        guard fd >= 0 else { throw fileFailure("Could not safely open authorized_keys") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == getuid(), info.st_size <= 1024 * 1024 else { throw fileFailure("Could not safely read authorized_keys") }
        var data = Data(), scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &scratch, scratch.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw fileFailure("Could not read authorized_keys") }
            if count == 0 { return data }
            data.append(contentsOf: scratch.prefix(count))
            guard data.count <= 1024 * 1024 else { throw fileFailure("authorized_keys is too large") }
        }
    }

    private static func replaceAuthorizedKeys(_ data: Data, _ directoryFD: Int32) throws {
        let name = ".harness-mobile-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw fileFailure("Could not stage authorized_keys") }
        defer { close(fd); _ = unlinkat(directoryFD, name, 0) }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = write(fd, base.advanced(by: offset), raw.count - offset)
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw fileFailure("Could not write the new authorized_keys; the original is preserved") }
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, name, directoryFD, "authorized_keys") == 0 else { throw fileFailure("Could not publish authorized_keys; the original is preserved") }
        _ = fsync(directoryFD)
    }
    private static func invalidKey() -> RemoteFailure { RemoteFailure(code: "invalidKey", message: "Provide one plain ssh-ed25519 public key without options or newlines") }
    private static func fileFailure(_ message: String) -> RemoteFailure { RemoteFailure(code: "keyInstallFailed", message: message) }
}
