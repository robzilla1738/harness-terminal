import Foundation
import HarnessCore
import HarnessScript

extension HarnessCLI {
    static func handlePlugin(_ args: [String]) throws {
        guard ProcessInfo.processInfo.environment["HARNESS_TUNNEL"] != "1", !args.contains("--host"), !args.contains("--remote") else { throw PluginTrustError.localOnly }
        let verb = args.count > 1 ? args[1] : "list"
        switch verb {
        case "list":
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let metadata = try TrustedPlugins.load().map { $0.manifest }
            print(String(decoding: try encoder.encode(metadata), as: UTF8.self))
        case "review", "trust":
            guard let path = flagValue(args, flag: "--manifest") else { throw activityArgumentErrorForPlugin("Use plugin review|trust --manifest /absolute/plugin.json; trust requires --approve after reviewing the source") }
            let plugin = try TrustedPlugins.prepare(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            if verb == "review" || !args.contains("--approve") { print(plugin.review); return }
            try TrustedPlugins.approve(plugin); print("Reviewed entry code approved locally for " + plugin.id)
        case "revoke":
            guard let id = flagValue(args, flag: "--id") else { throw PluginTrustError.missing }
            try TrustedPlugins.revoke(id); print("Plugin trust revoked for " + id)
        case "run":
            guard let id = flagValue(args, flag: "--id"), let action = flagValue(args, flag: "--action") else { throw PluginTrustError.missing }
            let source = try TrustedPlugins.source(plugin: id, action: action)
            let engine = try ScriptEngine(hosts: RemoteHostStore())
            let origin = ScriptOrigin(rawValue: flagValue(args, flag: "--origin") ?? "cli") ?? .cli
            engine.remoteControlEnabled = HarnessSettings.load().remoteControl
            if let client = try? makeClient(args) {
                let environment = APIEnvironment(environment: callerEnvironment(args) ?? [:])
                engine.call = { method, arguments in APIExecutor.call(method: method, arguments: arguments, client: client, environment: environment, exposure: .lua) }
            }
            switch HarnessAPI.arguments(from: flagValue(args, flag: "--args") ?? "{}") {
            case let .success(arguments): engine.setArguments(arguments)
            case let .failure(error): throw activityArgumentErrorForPlugin(error.message)
            }
            // Plugins are one invocation. Persistent event handlers remain explicit scripts.
            guard case .loaded = engine.load(source, from: "trusted-plugin:" + id + ":" + action, replacingFileLayer: false) else { throw activityArgumentErrorForPlugin("The approved plugin entry failed to execute. Review plugin source and dependencies before approving an update.") }
            runQueued(engine.takeQueued(), origin: origin, args: args)
            if engine.isStopped && engine.stopCode != 0 { exit(Int32(engine.stopCode)) }
        default: throw activityArgumentErrorForPlugin("Use plugin list|review|trust|revoke|run")
        }
    }
    private static func activityArgumentErrorForPlugin(_ message: String) -> NSError { NSError(domain: "HarnessPlugin", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }

    static func handleConfig(_ args: [String]) throws {
        let sub = args.count > 1 ? args[1] : ""
        let path = flagValue(args, flag: "--file") ?? ScriptConfigPath.resolve()
        switch sub {
        case "check":
            let report = ScriptEngine.check(path: path)
            print(report.text)
            if report.syntaxError != nil { exit(1) }
        case "reload":
            let remote = args.contains("--remote") || ProcessInfo.processInfo.environment["HARNESS_TUNNEL"] == "1"
            let file = URL(fileURLWithPath: path)
            let before = try? Data(contentsOf: file)
            let engine = try ScriptEngine()
            wireHostNote(engine, args: args)
            switch engine.reload(file: file, remote: remote) {
            case .loaded:
                if let before, (try? Data(contentsOf: file)) != before {
                    fputs("config reload changed the file\n", harnessStderr)
                    exit(1)
                }
                try publishScript(engine, args: args)
                print(engine.checkReport(path: path).text)
            case .refused:
                fputs("config reload refused from a remote connection\n", harnessStderr)
                exit(1)
            case let .syntax(message):
                fputs(message + "\n", harnessStderr)
                exit(1)
            }
        default:
            fputs("Usage: harness-cli config check|reload [--file path]\n", harnessStderr)
            exit(2)
        }
    }

    static let doUsage = """
    Usage: harness-cli do <action> [--args json] [--for a,b] [--all] [--fail-fast]
           harness-cli do <file.lua> | -e '<lua>' | -  [--args json]   (a script; harness.args is --args)
           harness-cli do --binding <key>                              (the Lua function bound to a key)
    """

    /// What `do` was asked to run: a named action from the config, or a script.
    enum DoTarget: Equatable {
        case action(String)
        case script(source: String, name: String)
        case binding(String)
    }

    /// `do --action name`, `do name`, `do file.lua` (ends in .lua or has a slash), `do -e code`,
    /// or `do -` (script on stdin).
    static func doTarget(_ args: [String]) throws -> DoTarget? {
        if let action = flagValue(args, flag: "--action"), !action.isEmpty { return .action(action) }
        if let spec = flagValue(args, flag: "--binding"), !spec.isEmpty { return .binding(spec) }
        if let code = flagValue(args, flag: "-e") { return .script(source: code, name: "-e") }
        let valueFlags: Set<String> = ["--action", "--binding", "--file", "--args", "--for", "--origin", "-e", "--host"]
        var index = 1
        while index < args.count {
            let word = args[index]
            if valueFlags.contains(word) { index += 2; continue }
            if word == "-" {
                return .script(source: String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self), name: "stdin")
            }
            if word.hasPrefix("-") { index += 1; continue }
            if word.hasSuffix(".lua") || word.contains("/") {
                let path = (word as NSString).expandingTildeInPath
                return .script(source: try String(contentsOfFile: path, encoding: .utf8), name: path)
            }
            return .action(word)
        }
        return nil
    }

    static func handleDo(_ args: [String]) throws {
        guard let target = try doTarget(args) else {
            fputs(doUsage + "\n", harnessStderr)
            exit(CLIExit.usage)
        }
        let path = flagValue(args, flag: "--file") ?? ScriptConfigPath.resolve()
        let engine = try ScriptEngine(hosts: RemoteHostStore())
        engine.tunnel = ProcessInfo.processInfo.environment["HARNESS_TUNNEL"] == "1"
        engine.remoteControlEnabled = HarnessSettings.load().remoteControl
        wireHostNote(engine, args: args)
        // Subscribe before anything runs, so an event the script waits for can't slip past.
        let client = try? makeClient(args)
        let feed = client.map { EventFeed(client: $0) }
        engine.poll = { feed?.poll() }
        if let client {
            let environment = APIEnvironment(environment: callerEnvironment(args) ?? [:])
            engine.call = { method, arguments in APIExecutor.call(method: method, arguments: arguments, client: client, environment: environment, exposure: .lua) }
            engine.log = { level, message in
                fputs("[\(level)] \(message)\n", harnessStderr)
                _ = try? client.request(.displayMessage(format: message, print: false), timeout: 2)
            }
        }
        // The config always loads first: its actions are callable from scripts.
        if FileManager.default.fileExists(atPath: path) {
            let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if case let .syntax(message) = engine.load(source, from: path, replacingFileLayer: false) {
                fputs(message + "\n", harnessStderr)
                exit(CLIExit.failed)
            }
        }
        let outcome: ScriptInvocation
        switch target {
        case let .action(action):
            let arguments = try actionArguments(args)
            let targets = try actionTargets(args)
            let actionOrigin = ScriptOrigin(rawValue: Self.flagValue(args, flag: "--origin") ?? "") ?? .cli
            outcome = targets.isEmpty
                ? engine.invoke(name: action, arguments: arguments, origin: actionOrigin)
                : engine.invokeAll(
                    name: action,
                    arguments: arguments,
                    targets: targets,
                    failFast: args.contains("--fail-fast"),
                    origin: actionOrigin
                )
        case let .binding(spec):
            switch engine.runBinding(spec: spec) {
            case .ran:
                outcome = ScriptInvocation(ran: true, queued: [], exitCode: 0, message: nil)
            case .notBound:
                outcome = ScriptInvocation(ran: false, queued: [], exitCode: Int(CLIExit.targetNotFound), message: "no Lua function is bound to \(spec)")
            case let .failed(message):
                outcome = ScriptInvocation(ran: true, queued: [], exitCode: Int(CLIExit.failed), message: "binding \(spec): \(message)")
            }
        case let .script(source, name):
            switch HarnessAPI.arguments(from: flagValue(args, flag: "--args") ?? "{}") {
            case let .success(arguments): engine.setArguments(arguments)
            case let .failure(error):
                fputs(error.message + "\n", harnessStderr)
                exit(CLIExit.usage)
            }
            engine.allowsHandlers = true
            if case let .syntax(message) = engine.load(source, from: name, replacingFileLayer: false) {
                fputs(message + "\n", harnessStderr)
                exit(CLIExit.failed)
            }
            engine.warnings.forEach { fputs("warning: \($0)\n", harnessStderr) }
            outcome = ScriptInvocation(ran: true, queued: [], exitCode: 0, message: nil)
        }
        if let message = outcome.message { fputs(message + "\n", harnessStderr) }
        let origin = ScriptOrigin(rawValue: flagValue(args, flag: "--origin") ?? ProcessInfo.processInfo.environment["HARNESS_ORIGIN"] ?? "") ?? .cli
        let flush = { (commands: [String]) in runQueued(commands, origin: origin, args: args) }
        flush(outcome.queued + engine.takeQueued())
        // Handlers keep a script alive until harness.stop() or Ctrl-C.
        engine.runHandlers(afterEach: { flush(engine.takeQueued()) })
        exit(engine.isStopped ? Int32(engine.stopCode) : Int32(outcome.exitCode))
    }

    /// `harness.queue` commands. From a key or the palette the app runs them (one per stdout
    /// line, see `SessionCoordinator.applyScriptResult`); from a shell they go to the daemon.
    private static func runQueued(_ commands: [String], origin: ScriptOrigin, args: [String]) {
        guard !commands.isEmpty else { return }
        if origin == .key || origin == .palette {
            commands.forEach { print(ScriptActionRunner.queuedLine($0)) }
            fflush(nil) // stdout; naming the C global trips Swift 6.0 strict concurrency on Linux
            return
        }
        guard let client = try? makeClient(args) else { return }
        for command in commands {
            do {
                try CommandRunner.run(command, client: client, focusSurface: callerEnvironment(args)?["HARNESS_SURFACE"])
            } catch {
                fputs("queued \(command): \(error)\n", harnessStderr)
            }
        }
    }

    private static func wireHostNote(_ engine: ScriptEngine, args: [String]) {
        engine.onHostsChanged = {
            guard let client = try? makeClient(args) else { return }
            _ = try? client.request(.noteHostsChanged)
        }
    }

    private static func publishScript(_ engine: ScriptEngine, args: [String]) throws {
        let manifest = ScriptManifest(
            generation: engine.generation,
            hash: engine.fingerprint,
            actions: engine.actions,
            bindingCount: engine.bindCount,
            bindings: engine.keymap.exportedBindings(),
            modes: engine.keymap.exportedModes()
        )
        try ScriptStore.save(manifest)
        if let client = try? makeClient(args) {
            _ = try? client.request(.publishKeymap(generation: engine.generation, hash: engine.fingerprint))
        }
    }

    private static func actionArguments(_ args: [String]) throws -> [String: String] {
        let raw = flagValue(args, flag: "--args") ?? "{}"
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            fputs("Arguments must be a JSON object\n", harnessStderr)
            exit(2)
        }
        var parsed: [String: String] = [:]
        for (key, value) in object {
            guard let text = value as? String else {
                fputs("Argument \(key) must be a string\n", harnessStderr)
                exit(2)
            }
            parsed[key] = text
        }
        return parsed
    }

    private static func actionTargets(_ args: [String]) throws -> [String] {
        var targets = (flagValue(args, flag: "--for") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard args.contains("--all") else { return targets }
        let client: DaemonClient
        do { client = try makeClient(args) } catch {
            fputs("\(error)\n", harnessStderr)
            exit(4)
        }
        guard case let .snapshot(snapshot) = try client.request(.getSnapshot) else {
            fputs("HarnessDaemon is not reachable\n", harnessStderr)
            exit(4)
        }
        targets += snapshot.workspaces.flatMap(\.sessions).map(\.id.uuidString)
        return targets
    }
}

private extension ScriptEngine {
    func checkReport(path: String) -> ConfigReport {
        ConfigReport(
            path: path,
            exists: true,
            bindings: bindCount,
            removals: removalCount,
            modes: keymap.modes.keys.sorted(),
            actions: actions.map(\.name).sorted(),
            warnings: warnings + keymap.warnings,
            syntaxError: nil
        )
    }
}
