import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

public enum ProcessCaptureError: Error, LocalizedError, Equatable {
    case timedOut, cancelled, outputLimit, pipeFailure
    public var errorDescription: String? {
        switch self {
        case .timedOut: "The command exceeded its time limit."
        case .cancelled: "The command was cancelled."
        case .outputLimit: "The command exceeded its output limit."
        case .pipeFailure: "The command's input or output pipe failed."
        }
    }
}

/// Drain both output pipes and feed stdin together, without unbounded read-to-end workers.
/// Deadlines include children that exit while a descendant keeps their output pipe open.
public enum ProcessCapture {
    public static func run(_ executable: URL, arguments: [String], stdin: Data? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval? = nil,
                           maxOutputBytes: Int = 64 * 1024 * 1024,
                           cancelled: () -> Bool = { false }) throws -> ProcessOutput {
        if cancelled() { throw ProcessCaptureError.cancelled }
        let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + max(0, $0) }
        let outputLimit = max(0, maxOutputBytes)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        let input = stdin.map { _ in Pipe() }
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()
        // A child may close stdin early. Block SIGPIPE only on this worker thread, and
        // consume a newly pending signal before restoring its original mask.
        var pipeSignal = sigset_t(), oldMask = sigset_t()
        sigemptyset(&pipeSignal)
        sigaddset(&pipeSignal, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &pipeSignal, &oldMask)
        defer {
            if sigismember(&oldMask, SIGPIPE) == 0 {
                var pending = sigset_t()
                sigpending(&pending)
                if sigismember(&pending, SIGPIPE) == 1 {
                    var signal: Int32 = 0
                    sigwait(&pipeSignal, &signal)
                }
            }
            pthread_sigmask(SIG_SETMASK, &oldMask, nil)
        }
        #if canImport(Darwin)
        if let input { _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        #endif
        let handles = [out.fileHandleForReading, err.fileHandleForReading] + (input.map { [$0.fileHandleForWriting] } ?? [])
        defer { for handle in handles { try? handle.close() } }
        var stdout = Data(), stderr = Data()
        var open = [true, true]
        var inputOpen = input != nil
        var inputOffset = 0
        do {
            for handle in handles {
                let flags = fcntl(handle.fileDescriptor, F_GETFL)
                guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                    throw ProcessCaptureError.pipeFailure
                }
            }
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while open.contains(true) || process.isRunning {
                if cancelled() { throw ProcessCaptureError.cancelled }
                if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw ProcessCaptureError.timedOut }
                var descriptors = handles.enumerated().map { index, handle in
                    pollfd(fd: index < 2 ? (open[index] ? handle.fileDescriptor : -1) : (inputOpen ? handle.fileDescriptor : -1),
                           events: Int16(index < 2 ? POLLIN : POLLOUT), revents: 0)
                }
                let result = poll(&descriptors, nfds_t(descriptors.count), 25)
                if result < 0, errno != EINTR { throw ProcessCaptureError.pipeFailure }
                for index in 0..<2 where open[index] && descriptors[index].revents != 0 {
                    let count = read(handles[index].fileDescriptor, &scratch, scratch.count)
                    if count > 0 {
                        guard count <= outputLimit - stdout.count - stderr.count else { throw ProcessCaptureError.outputLimit }
                        if index == 0 { stdout.append(contentsOf: scratch.prefix(count)) }
                        else { stderr.append(contentsOf: scratch.prefix(count)) }
                    } else if count == 0 { open[index] = false }
                    else if errno != EAGAIN && errno != EINTR { throw ProcessCaptureError.pipeFailure }
                }
                if inputOpen, let input, let stdin, descriptors[2].revents != 0 {
                    let count = stdin.withUnsafeBytes { raw -> Int in
                        guard inputOffset < raw.count, let base = raw.baseAddress else { return 0 }
                        return write(input.fileHandleForWriting.fileDescriptor, base.advanced(by: inputOffset), raw.count - inputOffset)
                    }
                    if count > 0 { inputOffset += count }
                    if inputOffset == stdin.count || count < 0 && errno == EPIPE {
                        try input.fileHandleForWriting.close()
                        inputOpen = false
                    } else if count < 0 && errno != EAGAIN && errno != EINTR { throw ProcessCaptureError.pipeFailure }
                }
            }
            process.waitUntilExit()
            return ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        } catch {
            // Foundation's Linux waitUntilExit can wait for descendants holding inherited
            // pipes. Close our ends and let Foundation reap asynchronously after bounded
            // termination; cancellation must not inherit a grandchild's lifetime.
            for handle in handles { try? handle.close() }
            let pid = process.processIdentifier
            let ownsGroup = getpgid(pid) == pid
            if process.isRunning { kill(ownsGroup ? -pid : pid, SIGTERM) }
            let grace = ProcessInfo.processInfo.systemUptime + 0.1
            while process.isRunning, ProcessInfo.processInfo.systemUptime < grace { usleep(5_000) }
            if process.isRunning { kill(ownsGroup ? -pid : pid, SIGKILL) }
            throw error
        }
    }
}
