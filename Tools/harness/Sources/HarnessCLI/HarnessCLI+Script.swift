import Foundation
import HarnessCore
import HarnessScript

extension HarnessCLI {
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

    static func handleDo(_ args: [String]) throws {
        guard let action = flagValue(args, flag: "--action"), !action.isEmpty else {
            fputs("Usage: harness-cli do --action <name> [--file path] [--args json] [--for a,b] [--all] [--fail-fast] [--origin key|palette|cli|api|script]\n", harnessStderr)
            exit(2)
        }
        let path = flagValue(args, flag: "--file") ?? ScriptConfigPath.resolve()
        let engine = try ScriptEngine(hosts: RemoteHostStore())
        engine.tunnel = ProcessInfo.processInfo.environment["HARNESS_TUNNEL"] == "1"
        engine.remoteControlEnabled = HarnessSettings.load().remoteControl
        wireHostNote(engine, args: args)
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if FileManager.default.fileExists(atPath: path) {
            if case let .syntax(message) = engine.load(source, from: path, replacingFileLayer: false) {
                fputs(message + "\n", harnessStderr)
                exit(1)
            }
        }
        let arguments = try actionArguments(args)
        let targets = try actionTargets(args)
        let origin = ScriptOrigin(rawValue: Self.flagValue(args, flag: "--origin") ?? "") ?? .cli
        let outcome = targets.isEmpty
            ? engine.invoke(name: action, arguments: arguments, origin: origin)
            : engine.invokeAll(
                name: action,
                arguments: arguments,
                targets: targets,
                failFast: args.contains("--fail-fast"),
                origin: origin
            )
        if let message = outcome.message { fputs(message + "\n", harnessStderr) }
        for name in outcome.queued { print(name) }
        exit(Int32(outcome.exitCode))
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
