import Foundation
import HarnessCore
import CHarnessSys
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A bounded nonblocking tee. Descriptor admission and stop share one lock;
/// no queued write can borrow a descriptor after it has been closed or reused.
final class TerminalOutputPipe: @unchecked Sendable {
    let process: Process
    let stdin: FileHandle
    private var identity: String?
    private var tokenStorage: UUID?
    var token: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return tokenStorage }
        set { lock.lock(); tokenStorage = newValue; lock.unlock() }
    }
    private let lock = NSLock()
    private var closed = false
    private var finishing = false
    private var failureClaimed = false
    private let writer = PtyInputWriter(queue: DispatchQueue(label: "com.harness.pipe-pane.write"), limit: 4 << 20)
    init(process: Process, stdin: FileHandle) throws {
        self.process = process; self.stdin = stdin
        let fd = stdin.fileDescriptor, flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ProcessCaptureError.pipeFailure }
        #if canImport(Darwin)
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw ProcessCaptureError.pipeFailure }
        #endif
    }
    func didStart() { lock.lock(); identity = ProcessScan.generation(process.processIdentifier); lock.unlock() }
    func feed(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !finishing else { return false }
        let fd = sysDup(stdin.fileDescriptor)
        guard fd >= 0 else { return false }
        return writer.write(data, master: (fd, 1))
    }
    func claimFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !finishing, !failureClaimed else { return false }
        failureClaimed = true; return true
    }
    /// Seal admission, write the already accepted tail, then send EOF. A stalled
    /// consumer gets a bounded grace period rather than an unbounded drain worker.
    func finish() {
        lock.lock()
        guard !closed, !finishing else { lock.unlock(); return }
        finishing = true
        let descriptor = sysDup(stdin.fileDescriptor)
        lock.unlock()
        if descriptor < 0 { stop(); return }
        if !writer.perform(afterInput: (descriptor, 1), apply: { [self] in endInput() }, cancel: { [weak self] in self?.stop() }) { stop() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [self] in stop() }
    }
    private func endInput() {
        lock.lock()
        if !closed { writer.reset(); try? stdin.close() }
        lock.unlock()
    }
    func stop() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; writer.reset(); try? stdin.close()
        let birth = identity, pid = process.processIdentifier
        lock.unlock()
        guard process.isRunning, let birth, ProcessScan.generation(pid) == birth else { return }
        let target = getpgid(pid) == pid ? -pid : pid
        _ = kill(target, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [process, birth, pid, target] in
            if process.isRunning, ProcessScan.generation(pid) == birth { _ = kill(target, SIGKILL) }
        }
    }
}

/// Entered before daemon bootstrap. Reset inherited ignored signals and give a
/// pipe consumer its own process group, then execute the explicitly supplied shell
/// command. No Harness service, store or user configuration is opened here.
public enum TerminalPipeWorker {
    public static func runWorker() -> Int32 {
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard arguments.count == 1, !arguments[0].isEmpty, arguments[0].utf8.count <= 65536, !arguments[0].contains("\0") else { return 2 }
        guard getpgrp() == getpid() || setsid() >= 0 else { return 2 }
        let strings = ["sh", "-c", arguments[0]].map { value in value.withCString { strdup($0) } }
        defer { for pointer in strings { free(pointer) } }
        guard strings.allSatisfy({ $0 != nil }) else { return 2 }
        var pointers = strings + [nil]
        harness_reset_signals()
        _ = pointers.withUnsafeMutableBufferPointer { execv("/bin/sh", $0.baseAddress!) }
        return 2
    }
}
