#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import HarnessCore

public enum RecordClient {
    public static func run(client: DaemonClient, surfaceID: String, outputPath: String, display: Bool) -> Int32 {
        let ended = DispatchSemaphore(value: 0)
        let output: (@Sendable (Data) -> Void)?
        if display { output = { data in writeOutput(data) } } else { output = nil }
        let recorder = LiveTerminalRecorder(client: client, surfaceID: surfaceID, url: URL(fileURLWithPath: outputPath), onUpdate: { status in
            if status.complete { ended.signal() }
        }, onOutput: output)
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler { recorder.stop() }; interrupt.resume(); defer { interrupt.cancel() }
        fputs("harness-cli record: passive recording; no input is captured (Ctrl-C to stop).\n", harnessStderr)
        if recorder.protectionKind == .ownerOnlyLinux { fputs("Linux recording storage is owner-only plaintext.\n", harnessStderr) }
        recorder.start(); ended.wait()
        let final = recorder.status
        if let failure = final.failure { fputs("harness-cli record: " + failure + "\n", harnessStderr); return 1 }
        fputs("harness-cli record: saved \(final.events) events → \(outputPath)\n", harnessStderr); return 0
    }
    private static func writeOutput(_ data: Data) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }; var offset = 0
            while offset < bytes.count {
                let count = write(STDOUT_FILENO, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }; guard count > 0 else { return }; offset += count
            }
        }
    }
}
