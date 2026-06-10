import Foundation
import HarnessCore

/// Daemon/server lifecycle + connection subcommands (attach, attach-window, record/
/// replay, remote, kill/start-server, stats/clients, doctor). Mechanically extracted from
/// `HarnessCLI.swift` (PR-32): zero logic change.
extension HarnessCLI {
    static func handleAttach(_ args: [String]) throws -> Int32 {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli attach --surface <id> [--detach-keys <bytes>] [--host <name>]\n", harnessStderr)
            return 64
        }
        var configuration = AttachClient.Configuration()
        switch resolveDetachSequence(args) {
        case .parsed(let seq): configuration.detachSequence = seq
        case .absent: break  // flag absent — keep the default
        case .invalid(let message): fputs(message, harnessStderr); return 64
        }
        let endpoint = try resolveEndpoint(args)
        return try AttachClient.run(surfaceID: surface, configuration: configuration, endpoint: endpoint)
    }

    /// Build the daemon client for this invocation, honouring a global `--host <name>` flag that
    /// connects to a remote daemon through an SSH tunnel (configured via `harness-cli remote add`).
    static func makeClient(_ args: [String]) throws -> DaemonClient {
        DaemonClient(endpoint: try resolveEndpoint(args))
    }

    /// Resolve the endpoint for this invocation: the local socket, or — when `--host <name>` is
    /// given — the local end of an SSH tunnel to the named remote daemon.
    static func resolveEndpoint(_ args: [String]) throws -> Endpoint {
        guard let hostName = flagValue(args, flag: "--host") else { return .localControlSocket }
        guard let host = RemoteHostStore().host(named: hostName) else {
            fputs("harness-cli: unknown --host '\(hostName)'. Add it with `harness-cli remote add`.\n", harnessStderr)
            exit(64)
        }
        return try SSHTunnelManager.shared.endpoint(for: host)
    }

    /// `remote <list|add|remove>` — manage saved remote daemons reached over SSH.
    static func handleRemote(_ args: [String]) throws -> Int32 {
        let store = RemoteHostStore()
        let sub = args.count > 1 ? args[1] : "list"
        switch sub {
        case "list":
            let hosts = store.load()
            if hosts.isEmpty {
                print("No remote hosts. Add one with: harness-cli remote add --name <name> --ssh <user@host>")
            }
            for h in hosts {
                let live = SSHTunnelManager.shared.isConnected(h.name) ? " [connected]" : ""
                print("\(h.name)\t\(h.sshTarget)\t\(h.remoteSocketPath)\(live)")
            }
            return 0
        case "add":
            guard let name = flagValue(args, flag: "--name"), let ssh = flagValue(args, flag: "--ssh") else {
                fputs("Usage: harness-cli remote add --name <name> --ssh <user@host> "
                    + "--socket <remote-path> [--ssh-arg <arg> ...]\n", harnessStderr)
                return 64
            }
            guard let socketPath = flagValue(args, flag: "--socket") else {
                fputs("harness-cli remote add: could not infer the remote socket path; pass --socket "
                    + "<remote-path> (see `harness-cli doctor` on the remote for its value).\n", harnessStderr)
                return 64
            }
            var sshArgs: [String] = []
            var i = 0
            while i < args.count {
                if args[i] == "--ssh-arg" {
                    // A trailing valueless `--ssh-arg` would silently drop the arg the user meant to
                    // pass through; fail loudly (exit 64) like the other dangling-flag guards (#92).
                    guard i + 1 < args.count else {
                        fputs("harness-cli remote add: --ssh-arg requires a value "
                            + "(e.g. --ssh-arg -p --ssh-arg 2222).\n", harnessStderr)
                        return 64
                    }
                    sshArgs.append(args[i + 1]); i += 2
                } else { i += 1 }
            }
            let result = store.upsert(RemoteHost(name: name, sshTarget: ssh, remoteSocketPath: socketPath, sshArgs: sshArgs))
            guard result.saved else {
                fputs("harness-cli remote add: failed to write \(HarnessPaths.remoteHostsURL.path) "
                    + "(check disk space and permissions).\n", harnessStderr)
                return 1
            }
            print("Added remote '\(name)' -> \(ssh) (\(socketPath))")
            return 0
        case "remove":
            guard let name = flagValue(args, flag: "--name") else {
                fputs("Usage: harness-cli remote remove --name <name>\n", harnessStderr)
                return 64
            }
            let result = store.remove(name: name)
            SSHTunnelManager.shared.stop(host: name)
            guard result.saved else {
                fputs("harness-cli remote remove: failed to write \(HarnessPaths.remoteHostsURL.path) "
                    + "(check disk space and permissions).\n", harnessStderr)
                return 1
            }
            print("Removed remote '\(name)'")
            return 0
        default:
            fputs("Usage: harness-cli remote <list|add|remove> ...\n", harnessStderr)
            return 64
        }
    }

    /// `record --surface <id> --output <file> [--display]` — record a surface's
    /// output to a JSON Lines file (see `RecordingEvent`); `--display` also mirrors
    /// the output to this terminal. Stops on Ctrl-C or when the surface closes.
    static func handleRecord(_ args: [String], client: DaemonClient) -> Int32 {
        guard let surface = flagValue(args, flag: "--surface"),
              let output = flagValue(args, flag: "--output") else {
            fputs("Usage: harness-cli record --surface <uuid> --output <file> [--display]\n", harnessStderr)
            return 64
        }
        return RecordClient.run(
            client: client, surfaceID: surface, outputPath: output,
            display: args.contains("--display")
        )
    }

    /// `replay <file> [--speed <n>] [--no-timing]` — play a recording back to this
    /// terminal. `--speed` scales the recorded timing (2 = twice as fast),
    /// `--no-timing` dumps everything instantly. Ctrl-C stops cleanly.
    static func handleReplay(_ args: [String]) -> Int32 {
        guard let file = positionalArgs(args, skippingValuesFor: ["--speed"]).first else {
            fputs("Usage: harness-cli replay <file> [--speed <n>] [--no-timing]\n", harnessStderr)
            return 64
        }
        let speed = Double(flagValue(args, flag: "--speed") ?? "1") ?? .nan
        guard speed > 0 else {
            fputs("harness-cli replay: --speed must be a positive number\n", harnessStderr)
            return 64
        }
        return ReplayClient.run(path: file, speed: speed, honorTiming: !args.contains("--no-timing"))
    }

    #if canImport(HarnessTerminalKit)
    /// Renders a whole tab (split layout) into the terminal via the compositor.
    static func handleAttachWindow(_ args: [String]) throws -> Int32 {
        let selector: WindowAttachClient.TabSelector
        if let tabID = flagValue(args, flag: "--tab") ?? flagValue(args, flag: "--window") {
            selector = .id(tabID)
        } else if let session = flagValue(args, flag: "--session") {
            selector = .session(session)
        } else {
            selector = .active
        }
        var configuration = WindowAttachClient.Configuration()
        switch resolveDetachSequence(args) {
        case .parsed(let seq):
            configuration.detachSequence = seq
            configuration.detachSequenceExplicit = true  // user opted into a custom escape sequence
        case .absent: break  // flag absent — keep the prefix-bound default detach
        case .invalid(let message): fputs(message, harnessStderr); return 64
        }
        return try WindowAttachClient.run(tab: selector, configuration: configuration)
    }
    #endif

    static func resolveDetachSequence(_ args: [String]) -> DetachKeys {
        guard let raw = flagValue(args, flag: "--detach-keys") else {
            // A dangling `--detach-keys` (last token, no value) must not silently keep the default:
            // the user asked for a custom sequence and would otherwise get a different one.
            if flagIsDangling(args, flag: "--detach-keys") {
                return .invalid("harness-cli: --detach-keys requires a value "
                    + "('C-a d', '0x01 0x64', or comma-separated decimal bytes).\n")
            }
            return .absent
        }
        guard let parsed = parseDetachSequence(raw) else {
            return .invalid(
                "harness-cli: invalid --detach-keys '\(raw)'. "
                + "Use 'C-a d', '0x01 0x64', or comma-separated decimal bytes.\n")
        }
        return .parsed(parsed)
    }

    /// Parse `C-a d`, `0x01 0x64`, or comma-separated decimal bytes into a raw
    /// byte sequence. Single-character tokens become their literal ASCII byte.
    static func parseDetachSequence(_ raw: String) -> [UInt8]? {
        let tokens = raw.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        var bytes: [UInt8] = []
        for token in tokens {
            if token.hasPrefix("0x"), let value = UInt8(token.dropFirst(2), radix: 16) {
                bytes.append(value)
            } else if let value = UInt8(token) {
                bytes.append(value)
            } else if token.count == 3, token.hasPrefix("C-") || token.hasPrefix("c-") {
                guard let last = token.last,
                      let ch = last.uppercased().first,
                      let scalar = ch.asciiValue else { return nil }
                bytes.append(scalar & 0x1f)
            } else if token.count == 1, let scalar = token.first?.asciiValue {
                bytes.append(scalar)
            } else {
                return nil
            }
        }
        return bytes.isEmpty ? nil : bytes
    }

    static func printDaemonStats(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .daemonStats)
        guard case let .daemonStats(stats) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(stats, args) {
            print("pid: \(stats.pid)")
            print("version: \(stats.version ?? "?") (\(stats.build.map(String.init) ?? "pre-handshake"))")
            print(String(format: "uptime: %.0fs", stats.uptimeSeconds))
            print("surfaces: \(stats.surfaceCount)")
            print("scrollback: \(stats.totalScrollbackBytes) bytes")
            print("clients: \(stats.clientCount)")
            print("subscribers: \(stats.subscriberCount)")
            print("snapshot-revision: \(stats.snapshotRevision)")
        }
    }

    static func printClients(_ args: [String], client: DaemonClient) throws {
        let response = try checkedRequest(client, .listClients)
        guard case let .clients(items) = response else { throw DaemonClientError.unexpectedResponse }
        try emit(items, args) {
            for item in items {
                let attached = item.attachedSurfaceIDs.isEmpty ? "-" : item.attachedSurfaceIDs.joined(separator: ",")
                print("\(item.id.uuidString)\t\(item.label)\t\(attached)\t\(item.connectedAt)")
            }
        }
    }

    static func handleDetachClient(_ args: [String], client: DaemonClient) throws {
        guard let raw = flagValue(args, flag: "--client"), let id = UUID(uuidString: raw) else {
            fputs("Usage: harness-cli detach-client --client <uuid>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .detachClient(clientID: id))
    }

    /// tmux `kill-server`, adapted to launchd supervision: SIGTERM stops the daemon
    /// gracefully; KeepAlive respawns it with sessions restored from layout.json. A
    /// permanent stop is launchctl's job, so say so instead of fighting it.
    /// Local-only by construction (PID file + signal): with `--host`, refuse loudly
    /// instead of SIGTERMing the LOCAL daemon while targeting a remote one.
    static func handleKillServer(_ args: [String]) {
        if flagValue(args, flag: "--host") != nil {
            fputs("kill-server: operates on the local daemon only — run it on the host (ssh <host> harness-cli kill-server)\n", harnessStderr)
            exit(64)
        }
        let raw = (try? String(contentsOf: HarnessPaths.daemonPIDURL, encoding: .utf8)) ?? ""
        guard let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
            fputs("kill-server: no daemon.pid — is the daemon running? (try: harness-cli ping)\n", harnessStderr)
            exit(1)
        }
        // PID-reuse guard: after an unclean shutdown the recorded PID can belong to an
        // unrelated process — never signal anything that isn't a live HarnessDaemon.
        guard isLiveHarnessDaemon(pid) else {
            fputs("kill-server: pid \(pid) from daemon.pid is not a running HarnessDaemon (stale file?) — nothing to signal\n", harnessStderr)
            exit(1)
        }
        guard kill(pid, SIGTERM) == 0 else {
            fputs("kill-server: kill(\(pid)) failed: \(String(cString: strerror(errno)))\n", harnessStderr)
            exit(1)
        }
        print("sent SIGTERM to HarnessDaemon (pid \(pid))")
        #if os(macOS)
        print("note: launchd KeepAlive restarts it (sessions restore from layout.json);")
        print("      to stop it for good: launchctl bootout gui/$(id -u)/\(HarnessPaths.launchAgentLabel)")
        #endif
    }

    /// `kill(pid, 0)` liveness probe + executable identity (mirrors
    /// `DaemonLifecycle.executablePath`, which the CLI target doesn't link).
    static func isLiveHarnessDaemon(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        #if canImport(Darwin)
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_pidpath(pid, ptr.baseAddress, UInt32(MAXPATHLEN))
        }
        guard length > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
        #else
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = readlink("/proc/\(pid)/exe", &buffer, buffer.count - 1)
        guard len > 0 else { return false }
        let path = String(decoding: buffer[0 ..< len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #endif
        return (path as NSString).lastPathComponent.contains("HarnessDaemon")
    }

    /// tmux `start-server`, adapted: ensure the daemon is up (ping → launchctl kickstart).
    /// The ping honours `--host` (tunnelled client); the kickstart cannot — refuse the
    /// remote form instead of starting the LOCAL LaunchAgent while the remote stays down.
    static func handleStartServer(_ args: [String], client: DaemonClient) {
        if case .pong? = try? client.request(.ping, timeout: 1) {
            print("daemon already running")
            return
        }
        if flagValue(args, flag: "--host") != nil {
            fputs("start-server: cannot start a remote daemon — start it on the host (systemd/launchctl or harness-cli install)\n", harnessStderr)
            exit(1)
        }
        #if os(macOS)
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "gui/\(getuid())/\(HarnessPaths.launchAgentLabel)"]
        try? kick.run()
        kick.waitUntilExit()
        if case .pong? = try? client.request(.ping, timeout: 3) {
            print("daemon started")
            return
        }
        fputs("start-server: could not start the daemon — run 'harness-cli install' (LaunchAgent) or open Harness.app\n", harnessStderr)
        exit(1)
        #else
        fputs("start-server: start HarnessDaemon directly (e.g. via systemd) on this platform\n", harnessStderr)
        exit(1)
        #endif
    }

    /// `doctor [--json] [--pretty]` — diagnose the daemon, control socket, paths, and integrations.
    /// Exits nonzero only on a clear failure (a misconfiguration or security issue); warnings
    /// (daemon not running, optional integrations absent) keep exit 0.
    static func runDoctor(_ args: [String], client: DaemonClient) throws {
        var daemonReachable = false
        if let response = try? client.request(.ping, timeout: 0.3), case .pong = response {
            daemonReachable = true
        }
        var stats: DaemonStats?
        if daemonReachable,
           let response = try? client.request(.daemonStats, timeout: 0.3),
           case let .daemonStats(s) = response {
            stats = s
        }
        let report = DoctorRunner.run(daemonReachable: daemonReachable, cliPath: resolvedCLIPath(), daemonStats: stats)
        if args.contains("--json") {
            print(try JSONOutputFormatter.encode(report, pretty: args.contains("--pretty")))
        } else {
            report.text().forEach { print($0) }
        }
        exit(report.exitCode)
    }
}
