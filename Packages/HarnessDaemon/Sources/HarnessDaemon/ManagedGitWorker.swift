import Foundation
import HarnessCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A repository lease is inherited as stdin by the job and Git, so a daemon
/// crash cannot release it while the accepted mutation is still running. Never
/// explicitly LOCK_UN: that would also unlock the inherited open description.
final class ManagedGitLease {
    let input: FileHandle
    init(url: URL, cancelled: () -> Bool) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL else { throw ManagedWorktreeError.identity }
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManagedWorktreeError.identity }
        var retained = false
        defer { if !retained { close(fd) } }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size == 0, info.st_nlink == 1, fchmod(fd, 0o600) == 0 else { throw ManagedWorktreeError.identity }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if cancelled() { throw ProcessCaptureError.cancelled }
            guard errno == EWOULDBLOCK || errno == EINTR, ProcessInfo.processInfo.systemUptime < deadline else { throw ManagedWorktreeError.busy }
            usleep(10_000)
        }
        input = FileHandle(fileDescriptor: fd, closeOnDealloc: true); retained = true
    }
    // Foundation may retain the Process's standardInput handle after exit. The
    // lease scope, rather than that retention, controls the parent's descriptor.
    deinit { try? input.close() }
}

public enum ManagedGitWorker {
    static func run(_ operation: String, record: ManagedWorktree, lease: ManagedGitLease, executable: URL, cancelled: () -> Bool) throws {
        let arguments = ["--managed-git-worker", operation, record.repository.worktree, record.directory, record.branch, record.baseCommit]
        let output = try ProcessCapture.run(executable, arguments: arguments, timeout: 35, inputHandle: lease.input,
            terminationGrace: 1, maxOutputBytes: 2 << 20, cancelled: cancelled)
        guard output.status == 0 else { throw GitOperationError.command }
    }
    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock(); private var stopped = false
        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func isStopped() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    }
    public static func runWorker() -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst(2))
        guard args.count == 5, ["add", "remove"].contains(args[0]),
              args[1].hasPrefix("/"), args[2].hasPrefix("/"), args.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              let id = UUID(uuidString: URL(fileURLWithPath: args[2]).lastPathComponent),
              args[3] == "harness/" + id.uuidString.lowercased(), [40, 64].contains(args[4].count), args[4].allSatisfy(\.isHexDigit) else { return 2 }
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_size == 0, info.st_nlink == 1, info.st_mode & 0o777 == 0o600,
              flock(STDIN_FILENO, LOCK_EX | LOCK_NB) == 0 else { return 2 }
        // Cancellation kills this isolated group, including Git and its children.
        guard getpgrp() == getpid() || setsid() >= 0 else { return 2 }
        let cancellation = Cancellation()
        var signals: [DispatchSourceSignal] = []
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
            source.setEventHandler { cancellation.stop() }; source.resume(); signals.append(source)
        }
        defer { for source in signals { source.cancel() } }
        do {
            let command = args[0] == "add" ? ["worktree", "add", "-b", args[3], "--", args[2], args[4]] : ["worktree", "remove", "--", args[2]]
            _ = try HarnessGit.run(directory: args[1], arguments: command, timeout: 30, inputHandle: .standardInput, cancelled: cancellation.isStopped)
            return 0
        } catch {
            // Release the inherited lease only after the whole mutation group has
            // stopped. Durable metadata remains reconcilable by the next daemon.
            _ = kill(-getpid(), SIGTERM); usleep(100_000); _ = kill(-getpid(), SIGKILL)
            return 2
        }
    }
}
