import Foundation

/// Exit status plus everything a child wrote to stdout and stderr.
public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

/// Runs a child to completion and captures both streams without deadlocking.
/// Both pipes drain concurrently, and stdin is fed off-thread, so a child that writes
/// more than a pipe buffer (~64 KiB) to either stream still exits.
public enum ProcessCapture {
    public static func run(
        _ executable: URL,
        arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        try process.run()

        let group = DispatchGroup()
        let errorBox = DataBox()
        DispatchQueue.global(qos: .utility).async(group: group) {
            errorBox.data = err.fileHandleForReading.readDataToEndOfFile()
        }
        if let input, let stdin {
            DispatchQueue.global(qos: .utility).async(group: group) {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus, stdout: output, stderr: errorBox.data)
    }
}

/// Written by one background reader, read after `group.wait()`.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
