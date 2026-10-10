import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Authenticated uploads never expose a partial file or follow a replacement link.
enum PastedFiles {
    struct Failure: Error { var message: String }
    static let maxBytes = 11 * 1024 * 1024
    static func write(_ data: Data, named name: String, in directory: URL = HarnessPaths.pastedImagesDirectory) -> Result<String, Failure> {
        guard data.count <= maxBytes else { return .failure(Failure(message: "file is larger than \(maxBytes / 1024 / 1024) MB")) }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { return .failure(Failure(message: "The private upload directory is unavailable.")) }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return .failure(Failure(message: "The private upload directory is unavailable.")) }; defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, fchmod(parent, 0o700) == 0 else { return .failure(Failure(message: "The upload directory must belong to the current user.")) }
        sweep(directory, parent: parent)
        let base = (name as NSString).lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\:").union(.controlCharacters)).joined(separator: "-")
        let safe = base.isEmpty || base.hasPrefix(".") ? "pasted" : String(base.prefix(120))
        let filename = UUID().uuidString + "-" + safe
        let fd = openat(parent, filename, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failure(Failure(message: "The private upload file could not be created.")) }
        var complete = false
        defer { close(fd); if !complete { _ = unlinkat(parent, filename, 0) } }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                #if canImport(Darwin)
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                #else
                Glibc.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                #endif
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return .failure(Failure(message: "The upload could not be written completely.")) }; offset += count
        }
        guard fsync(fd) == 0, fsync(parent) == 0 else { return .failure(Failure(message: "The upload could not be saved completely.")) }
        complete = true; return .success(directory.appendingPathComponent(filename).path)
    }
    private static func sweep(_ directory: URL, parent: Int32) {
        let cutoff = Date().addingTimeInterval(-86400).timeIntervalSince1970
        for url in ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).prefix(512) {
            let name = url.lastPathComponent
            guard name.count > 37, UUID(uuidString: String(name.prefix(36))) != nil else { continue }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { continue }
            #if canImport(Darwin)
            let modified = info.st_mtimespec.tv_sec
            #else
            let modified = info.st_mtim.tv_sec
            #endif
            if Double(modified) < cutoff { _ = unlinkat(parent, name, 0) }
        }
    }
}
