import Foundation
import HarnessCore
import HarnessDaemonCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

if CommandLine.arguments.dropFirst().first == "--terminal-pipe-worker" { exit(TerminalPipeWorker.runWorker()) }

let ownership: DaemonInstanceLock
let service: SessionHostService
nonisolated(unsafe) var signals: [DispatchSourceSignal] = []
do {
    ownership = try DaemonInstanceLock()
    switch DaemonOwnership.probe() {
    case .alive, .uncertain: throw SessionHostStartupError.alreadyOwned
    case .absent: break
    }
    try HarnessPaths.ensureDirectories()
    try "\(getpid())\n".write(to: HarnessPaths.daemonPIDURL, atomically: true, encoding: .utf8)
    _ = chmod(HarnessPaths.daemonPIDURL.path, 0o600)
    ignoreSIGPIPE()
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    service = SessionHostService(daemonExecutable: HarnessToolLocator.companion("HarnessDaemon", to: executable))
    service.onShutdown = {
        DaemonLifecycle.removeOwnedPIDFile(at: HarnessPaths.daemonPIDURL, ownPID: getpid())
        exit(0)
    }
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
        source.setEventHandler { if service.stop() { service.onShutdown?() } }
        source.resume(); signals.append(source)
    }
    try service.start()
    dispatchMain()
} catch {
    DaemonLifecycle.removeOwnedPIDFile(at: HarnessPaths.daemonPIDURL, ownPID: getpid())
    fputs("HarnessSessionHost: \(error.localizedDescription); startup refused without interrupting an existing owner.\n", harnessStderr)
    exit(1)
}
enum SessionHostStartupError: Error { case alreadyOwned }
