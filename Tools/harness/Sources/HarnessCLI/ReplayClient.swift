#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore

/// `harness-cli replay` — plays a recording (see ``RecordingEvent``) back to the
/// local terminal by writing the recorded `output` bytes to stdout.
///
/// Playback honors the recorded inter-event timing on a monotonic, anti-drift
/// schedule (each write targets an absolute time from playback start, so a slow
/// write never accumulates lag). `--speed` scales the timing; `--no-timing`
/// dumps everything instantly. Ctrl-C stops playback cleanly — there is no file
/// being written, so nothing can be corrupted.
public enum ReplayClient {
    public static func run(path: String, speed: Double, honorTiming: Bool) -> Int32 {
        let text: String
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            text = String(decoding: data, as: UTF8.self)
        } catch {
            fputs("harness-cli replay: cannot read \(path): \(error)\n", harnessStderr)
            return 66 // EX_NOINPUT
        }

        let (events, skipped) = TerminalRecordingCodec.decode(text)
        if skipped > 0 {
            fputs("harness-cli replay: skipped \(skipped) malformed line(s)\n", harnessStderr)
        }
        let steps = TerminalReplay.steps(from: events, honorTiming: honorTiming, speed: speed)

        let player = ReplayPlayer()
        player.play(steps: steps)
        return 0
    }
}

// MARK: - Player

private final class ReplayPlayer: @unchecked Sendable {
    /// Signaled by the SIGINT handler to wake an in-progress sleep.
    private let interruptedSemaphore = DispatchSemaphore(value: 0)
    private let interrupted = InterruptFlag()
    private var sigintSource: DispatchSourceSignal?

    func play(steps: [ReplayStep]) {
        installInterruptHandler()
        defer { sigintSource?.cancel() }

        let start = DispatchTime.now()
        var elapsedMs = 0
        for step in steps {
            if interrupted.value { break }
            elapsedMs += step.delayMs
            if step.delayMs > 0 {
                // Absolute target from playback start → no cumulative drift; if
                // we're already behind, `wait` returns immediately and catches up.
                let target = start + .milliseconds(elapsedMs)
                if interruptedSemaphore.wait(timeout: target) == .success { break }
            }
            writeOut(step.data)
        }
    }

    private func installInterruptHandler() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.interrupted.set()
            self.interruptedSemaphore.signal()
        }
        source.resume()
        sigintSource = source
    }

    private func writeOut(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = write(STDOUT_FILENO, base.advanced(by: written), raw.count - written)
                if n > 0 { written += n; continue }
                if n < 0, errno == EINTR { continue }
                return
            }
        }
    }
}

/// Minimal lock-guarded boolean flag (set-once), shared between the SIGINT
/// handler and the play loop. Not `swift-atomics` — HarnessCLI has no such dep.
private final class InterruptFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock(); flag = true; lock.unlock()
    }
}
