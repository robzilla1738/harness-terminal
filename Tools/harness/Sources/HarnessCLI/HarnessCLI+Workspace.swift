#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import HarnessCore

extension HarnessCLI {
    static func eventLines(snapshot: SessionSnapshot, agents: [AgentSessionSummary]) throws -> [String] {
        try ControlPlane.events(snapshot: snapshot, agents: agents).map { try $0.jsonLine() }
    }

    static func handleSizeMode(_ args: [String], client: DaemonClient) throws {
        let modeName = flagValue(args, flag: "--mode") ?? args.dropFirst().first { !$0.hasPrefix("-") }
        guard let modeName, let mode = SurfaceSizeMode(rawValue: modeName) else {
            fputs("Usage: harness-cli size-mode <smallest|owner>\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .setSurfaceSizeMode(mode))
        print(mode.rawValue)
    }

    static func handleTakeSurface(_ args: [String], client: DaemonClient) throws {
        guard let surface = flagValue(args, flag: "--surface") else {
            fputs("Usage: harness-cli take-surface --surface <id> [--client <uuid>]\n", harnessStderr)
            exit(1)
        }
        let clientID: UUID
        switch optionalUUIDFlag(args, flag: "--client") {
        case let .valid(id):
            clientID = id
        case .absent:
            guard case let .clients(rows) = try checkedRequest(client, .listClients),
                  let attached = rows.first(where: { $0.attachedSurfaceIDs.contains(surface) })
            else {
                fputs("take-surface: no connected client is attached to \(surface)\n", harnessStderr)
                exit(1)
            }
            clientID = attached.id
        case .dangling:
            fputs("take-surface: --client requires a client id\n", harnessStderr)
            exit(1)
        case let .invalid(raw):
            fputs("take-surface: --client '\(raw)' is not a UUID\n", harnessStderr)
            exit(1)
        }
        _ = try checkedRequest(client, .takeSurface(surfaceID: surface, clientID: clientID))
    }

    static func handleSaveLayout(_ args: [String], client: DaemonClient) throws {
        guard let name = flagValue(args, flag: "--name"), !name.isEmpty else {
            fputs("Usage: harness-cli save-layout --name <name>\n", harnessStderr)
            exit(1)
        }
        guard case let .snapshot(snapshot) = try checkedRequest(client, .getSnapshot),
              let tab = snapshot.activeWorkspace?.activeTab
        else {
            fputs("save-layout: no active tab\n", harnessStderr)
            exit(1)
        }
        var programs: [String: String] = [:]
        var cwds: [String: String] = [:]
        for leaf in tab.rootPane.allLeaves() {
            let id = leaf.surfaceID.uuidString
            guard case let .text(json) = try checkedRequest(client, .surfaceContext(surfaceID: id)),
                  let data = json.data(using: .utf8),
                  let context = try? JSONDecoder().decode(ControlPlane.SurfaceContext.self, from: data)
            else { continue }
            if !context.executable.isEmpty { programs[id] = context.executable }
            if !context.cwd.isEmpty { cwds[id] = context.cwd }
        }
        let layout = NamedLayoutStore.capture(name: name, tab: tab, programs: programs, cwds: cwds)
        try NamedLayoutStore.save(layout, directory: layoutDirectory())
        print(name)
    }

    static func handleRestoreLayout(_ args: [String], client: DaemonClient) throws {
        guard let name = flagValue(args, flag: "--name"), !name.isEmpty else {
            fputs("Usage: harness-cli restore-layout --name <name>\n", harnessStderr)
            exit(1)
        }
        let layout = try NamedLayoutStore.load(name: name, directory: layoutDirectory())
        let plan = NamedLayoutStore.restorePlan(layout)
        for action in plan {
            switch action {
            case let .session(_, cwd, program):
                print("session\t\(cwd)\t\(program)")
            case let .split(target, direction, ratio, cwd, program):
                print("split\t\(target)\t\(direction.rawValue)\t\(ratio)\t\(cwd)\t\(program)")
            }
        }
        guard case let .workspaces(workspaces) = try checkedRequest(client, .listWorkspaces),
              let workspace = workspaces.first
        else {
            fputs("restore-layout: no workspace\n", harnessStderr)
            exit(1)
        }
        try LayoutApplication.apply(plan: plan, workspaceID: workspace.id) { request in
            try checkedRequest(client, request)
        }
    }

    static func handleEvents(_ args: [String], client: DaemonClient) throws {
        if args.contains("--follow") {
            try followEvents(args, client: client)
            return
        }
        guard case let .snapshot(snapshot) = try checkedRequest(client, .getSnapshot) else {
            fputs("events: snapshot unavailable\n", harnessStderr)
            exit(1)
        }
        let agents: [AgentSessionSummary]
        if case let .agents(rows) = try checkedRequest(client, .listAgents) {
            agents = rows
        } else {
            agents = []
        }
        for line in try eventLines(snapshot: snapshot, agents: agents) {
            print(line)
        }
    }

    /// Live NDJSON. A TTY gets one human line per event unless `--json` is set.
    /// `HARNESS_SESSION` pins the stream unless `--session` does. `--all` adds server events.
    static func followEvents(_ args: [String], client: DaemonClient) throws {
        let fromEnv = ProcessInfo.processInfo.environment["HARNESS_SESSION"]
        let envSession = (fromEnv?.isEmpty == false) ? fromEnv : nil
        let pinned = flagValue(args, flag: "--session") ?? envSession
        let human = isatty(STDOUT_FILENO) != 0 && !args.contains("--json")
        try client.followEvents(sessionID: pinned, includeServer: args.contains("--all")) { event in
            if human {
                print(event.humanLine())
            } else if let line = try? event.jsonLine() {
                print(line)
            }
            fflush(stdout)
        }
    }

    static func handleProcess(_ args: [String], client: DaemonClient) throws {
        let surface = try flagValue(args, flag: "--surface") ?? firstSurfaceID(client)
        guard let surface else {
            fputs("Usage: harness-cli process --surface <id>\n", harnessStderr)
            exit(1)
        }
        guard case let .text(json) = try checkedRequest(client, .foregroundProcess(surfaceID: surface)) else {
            fputs("process: no record\n", harnessStderr)
            exit(1)
        }
        print(json)
    }

    static func handleFindFiles(_ args: [String]) throws {
        let query = args.dropFirst().last { !$0.hasPrefix("-") && flagValue(args, flag: "--root") != $0 && flagValue(args, flag: "--host") != $0 }
        guard let query, !query.isEmpty else {
            fputs("Usage: harness-cli find-files [--root <dir>] [--host <name>] <query>\n", harnessStderr)
            exit(1)
        }
        let root = flagValue(args, flag: "--root") ?? FileManager.default.currentDirectoryPath
        let entries: [String]
        if let hostName = flagValue(args, flag: "--host") {
            let host = try requireHost(hostName)
            let argv = ControlPlane.sshFindArguments(target: host.sshTarget, extra: host.sshArgs, root: root)
            let output = try runSSH(argv, stdin: nil)
            entries = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        } else {
            entries = ControlPlane.localEntries(root: URL(fileURLWithPath: root))
        }
        for path in ControlPlane.lookup(query: query, entries: entries) {
            print(path)
        }
    }

    static func handleCopyFile(_ args: [String]) throws {
        guard let from = flagValue(args, flag: "--from"), let to = flagValue(args, flag: "--to") else {
            fputs("Usage: harness-cli copy-file --from <path> --to <path> [--push|--pull] [--host <name>]\n", harnessStderr)
            exit(1)
        }
        let push = args.contains("--push") || !args.contains("--pull")
        if let hostName = flagValue(args, flag: "--host") {
            let host = try requireHost(hostName)
            if push {
                try ControlPlane.copy(from: from, to: to, read: ControlPlane.localRead) { _, data in
                    let argv = ControlPlane.sshWriteArguments(target: host.sshTarget, extra: host.sshArgs, path: to)
                    _ = try runSSH(argv, stdin: data)
                }
            } else {
                try ControlPlane.copy(from: from, to: to, read: { path in
                    let argv = ControlPlane.sshReadArguments(target: host.sshTarget, extra: host.sshArgs, path: path)
                    return try runSSH(argv, stdin: nil)
                }, write: ControlPlane.localWrite)
            }
        } else {
            try ControlPlane.copy(
                from: from,
                to: to,
                read: ControlPlane.localRead,
                write: ControlPlane.localWrite
            )
        }
    }

    static func layoutDirectory() -> URL {
        HarnessPaths.sessionsDirectory.appendingPathComponent("layouts", isDirectory: true)
    }

    private static func firstSurfaceID(_ client: DaemonClient) throws -> String? {
        guard case let .surfaces(surfaces) = try checkedRequest(client, .listSurfaces) else { return nil }
        return surfaces.first?.surfaceID
    }

    private static func requireHost(_ name: String) throws -> RemoteHost {
        guard let host = RemoteHostStore().load().first(where: { $0.name == name }) else {
            fputs("harness-cli: unknown --host '\(name)'. Add it with `harness-cli remote add`.\n", harnessStderr)
            exit(1)
        }
        return host
    }

    static func runSSH(_ arguments: [String], stdin: Data?) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Array(arguments.dropFirst())
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        if let stdin {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "HarnessCLI", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: message.isEmpty ? "ssh exited \(process.terminationStatus)" : message,
            ])
        }
        return data
    }
}
