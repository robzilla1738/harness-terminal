import Foundation
import HarnessDaemonCore

let server = DaemonServer()
do {
    try server.start()
    AgentScanner.shared.start(registry: server.registry)
    server.runLoop()
} catch {
    fputs("HarnessDaemon failed: \(error)\n", stderr)
    exit(1)
}
