import Foundation
import HarnessCore
import HarnessTheme

extension HarnessCLI {
    static func handleImport(_ args: [String]) throws {
        guard args.count > 1 else { throw SetupError.invalid("Use import tmux, iterm-colors, or ghostty. Preview is the default; --dry-run performs no writes.") }
        let kind = args[1], write = args.contains("--write") && !args.contains("--dry-run")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func printJSON<T: Encodable>(_ value: T) throws { print(String(decoding: try encoder.encode(value), as: UTF8.self)) }
        func input(_ limit: Int = 4 << 20) throws -> Data {
            guard let path = flagValue(args, flag: "--input"), let data = try PrivateFile.read(URL(fileURLWithPath: path), maximumBytes: limit) else { throw SetupError.invalid("Provide an owner-readable --input file.") }
            return data
        }
        switch kind {
        case "tmux":
            let snapshot: TmuxImportSnapshot
            if flagValue(args, flag: "--input") != nil { snapshot = try JSONDecoder().decode(TmuxImportSnapshot.self, from: input()) }
            else {
                guard !write else { throw SetupError.invalid("Capture and review an import tmux preview first. Saving requires --input SNAPSHOT.json --session '$ID' --reviewed --write.") }
                snapshot = try TmuxSnapshotCapture.capture(executable: flagValue(args, flag: "--executable").map { URL(fileURLWithPath: $0) } ?? TmuxSnapshotCapture.executable(), socketPath: flagValue(args, flag: "--socket"), sessionID: flagValue(args, flag: "--session"))
            }
            let proposals = try TmuxLayoutImport.proposals(snapshot)
            if write {
                guard args.contains("--reviewed"), let id = flagValue(args, flag: "--session"), let proposal = proposals.first(where: { $0.sourceSessionID == id }) else { throw SetupError.invalid("Review the preview, then select --session '$ID' --reviewed --write.") }
                let response = try makeClient(args).requestForCurrentClient(.library(.save(proposal.setup)))
                guard case .ok = response else {
                    if case let .error(message) = response { throw SetupError.invalid(message) }
                    throw DaemonClientError.unexpectedResponse
                }
                print("Saved " + proposal.setup.name + ". No PTYs were acquired or commands executed.")
            } else {
                struct Preview: Encodable { var snapshot: TmuxImportSnapshot; var proposals: [TmuxSetupProposal] }
                try printJSON(Preview(snapshot: snapshot, proposals: proposals))
                if let output = flagValue(args, flag: "--snapshot-output"), !args.contains("--dry-run") {
                    let url = URL(fileURLWithPath: output), prior = try PrivateFile.read(url)
                    _ = try PrivateFile.replace(url, data: encoder.encode(snapshot), expected: prior, backup: true)
                }
            }
        case "iterm-colors":
            guard let path = flagValue(args, flag: "--input"), let variant = ITermColorImport.Variant(rawValue: flagValue(args, flag: "--variant") ?? "base") else { throw SetupError.invalid("Use --input FILE.itermcolors [--variant base|dark|light].") }
            let proposal = try ITermColorImport.parse(input(), name: flagValue(args, flag: "--name") ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, variant: variant)
            struct Preview: Encodable { var document: ThemeDocument; var warnings: [String] }
            try printJSON(Preview(document: proposal.document, warnings: proposal.warnings))
            if write {
                guard args.contains("--reviewed") else { throw SetupError.invalid("Preview the colors before adding --reviewed --write.") }
                let directory = flagValue(args, flag: "--themes-directory").map { URL(fileURLWithPath: $0) } ?? HarnessPaths.themesDirectory
                let url = try ThemeFileService().install(proposal.document, into: directory)
                fputs("Installed " + url.path + "; existing files receive a private backup. Settings were not changed.\n", harnessStderr)
            }
        case "ghostty":
            guard let text = String(data: try input(), encoding: .utf8) else { throw SetupError.invalid("Ghostty configuration must be UTF-8.") }
            let url = flagValue(args, flag: "--settings").map { URL(fileURLWithPath: $0) } ?? HarnessPaths.settingsURL
            let prior = try PrivateFile.read(url), current = try prior.map { try HarnessSettings.reload(data: $0) } ?? HarnessSettings()
            var imported = TerminalConfigImporter.parse(text); imported.sourceName = "Ghostty"
            let patch = try SettingsImport(current: current, imported: imported)
            struct Preview: Encodable { var changes: [SettingsImportChange]; var skipped: [String]; var conflicts: [String] }
            let conflicts = imported.paletteShortcuts.sorted { $0.key < $1.key }.flatMap { action, chord in
                current.paletteShortcuts.filter { $0.key != action && $0.value == chord }.map { chord + " is already assigned to " + $0.key }
            }
            try printJSON(Preview(changes: patch.changes, skipped: imported.skippedKeys, conflicts: conflicts))
            if write {
                guard args.contains("--reviewed"), let raw = flagValue(args, flag: "--select") else { throw SetupError.invalid("Choose reviewed --select field,field --reviewed --write. Unsupported bindings and font size are not applied.") }
                let backup = try patch.applyFile(at: url, expected: prior, selected: Set(raw.split(separator: ",").map(String.init)))
                fputs("Applied selected settings" + (backup.map { "; backup: " + $0.path } ?? "") + "\n", harnessStderr)
            }
        default: throw SetupError.invalid("Unknown importer. Use tmux, iterm-colors, or ghostty.")
        }
    }
}
