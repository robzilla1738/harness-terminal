import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Bounded owner-file operations for local settings, trusted configuration and explicit artifacts.
/// Preparing an edit is read-only; explicit replacement retains an owner-only backup.
public enum PrivateFile {
    public static func read(_ url: URL, maximumBytes: Int = 4 << 20) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw Failure.unavailable }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw Failure.unavailable }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Darwin)
                Darwin.read(fd, bytes.baseAddress, bytes.count)
                #else
                Glibc.read(fd, bytes.baseAddress, bytes.count)
                #endif
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0, result.count + count <= maximumBytes else { throw Failure.unavailable }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
    @discardableResult
    public static func replace(_ url: URL, data: Data, expected: Data?, backup: Bool = true, maximumBytes: Int = 4 << 20) throws -> URL? {
        guard maximumBytes > 0, maximumBytes <= 128 << 20, data.count <= maximumBytes else { throw Failure.unavailable }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("." + url.lastPathComponent + ".harness-lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              fchmod(fd, 0o600) == 0 else { throw Failure.unavailable }
        let deadline = Date().addingTimeInterval(3)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw Failure.busy }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { _ = flock(fd, LOCK_UN) }
        guard try read(url, maximumBytes: maximumBytes) == expected else { throw Failure.changed }
        if expected == data { return nil }
        let stage = directory.appendingPathComponent("." + url.lastPathComponent + ".stage-" + UUID().uuidString)
        defer { _ = unlink(stage.path) }
        try writeNew(stage, data: data)
        guard try read(stage, maximumBytes: maximumBytes) == data, try read(url, maximumBytes: maximumBytes) == expected else { throw Failure.changed }
        var backupURL: URL?
        if backup, let expected {
            let copy = directory.appendingPathComponent(url.lastPathComponent + ".harness-bak-" + UUID().uuidString)
            try writeNew(copy, data: expected); backupURL = copy
        }
        guard try read(url, maximumBytes: maximumBytes) == expected, rename(stage.path, url.path) == 0 else { throw Failure.changed }
        let directoryFD = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw Failure.unavailable }; defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw Failure.unavailable }
        return backupURL
    }
    private static func writeNew(_ url: URL, data: Data) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        var complete = false
        defer { close(fd); if !complete { _ = unlink(url.path) } }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                #if canImport(Darwin)
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #else
                Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                #endif
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure.unavailable }; offset += count
        }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
        complete = true
    }
    public enum Failure: Error, LocalizedError {
        case unavailable, changed, busy
        public var errorDescription: String? {
            switch self {
            case .unavailable: "The local file is not an owned regular file, is too large, or could not be saved."
            case .changed: "The file changed while the edit was being prepared; review a fresh version."
            case .busy: "Another configuration edit is in progress; retry shortly."
            }
        }
    }
}
