import Foundation

/// Loads and saves `keybindings.json`. Defaults from `KeyTableSet.defaults`
/// are merged in on load so the file always reflects the current default set
/// plus the user's overrides — and removing a binding from the file resets
/// it to default on the next launch.
public enum KeybindingsStore {
    public static var fileURL: URL {
        HarnessPaths.applicationSupport.appendingPathComponent("keybindings.json")
    }

    public static func load() -> KeyTableSet {
        let defaults = KeyTableSet.defaults
        guard let data = try? Data(contentsOf: fileURL) else {
            // Absent → best-effort seed; if the disk is read-only or directories aren't
            // writable, the in-memory defaults are still fine to use for this run.
            _ = try? save(defaults)
            return defaults
        }
        guard let stored = try? JSONDecoder().decode(KeyTableSet.self, from: data) else {
            // Present but unreadable: preserve it as `.corrupt` for recovery rather than
            // silently overwriting the user's bindings with defaults. Mirrors
            // SessionStore/OptionStore — return defaults WITHOUT rewriting the file.
            HarnessPaths.backupCorruptFile(at: fileURL, label: "Harness")
            return defaults
        }
        // Merge: stored tables win for any spec they explicitly define, but
        // defaults fill in unset spec slots and unset tables. Removing an
        // entry from the file = falling back to default — EXCEPT specs the
        // user explicitly unbound (tombstoned via `unbind-key`), which must
        // not resurrect on reload.
        var merged = migrateStoredDefaults(stored)
        for defaultTable in defaults.tableList {
            if var existing = merged.table(defaultTable.id) {
                for binding in defaultTable.bindings
                where existing.lookup(binding.spec) == nil && !existing.isDisabled(binding.spec) {
                    existing.set(binding)
                }
                if let i = merged.tableList.firstIndex(where: { $0.id == defaultTable.id }) {
                    merged.tableList[i] = existing
                }
            } else {
                merged.tableList.append(defaultTable)
            }
        }
        return merged
    }

    private static func migrateStoredDefaults(_ stored: KeyTableSet) -> KeyTableSet {
        var migrated = stored
        replaceIfShippedDefault(&migrated, spec: KeySpec(key: "n"), oldCommand: .nextWindow, oldNote: "Next tab")
        replaceIfShippedDefault(&migrated, spec: KeySpec(key: "p"), oldCommand: .previousWindow, oldNote: "Previous tab")
        for index in 0 ... 9 {
            replaceIfShippedDefault(
                &migrated,
                spec: KeySpec(key: String(index)),
                oldCommand: .selectWorkspace(index: index),
                oldNote: "Workspace \(index)"
            )
        }
        return migrated
    }

    private static func replaceIfShippedDefault(
        _ tables: inout KeyTableSet,
        spec: KeySpec,
        oldCommand: Command,
        oldNote: String
    ) {
        guard let current = tables.table(.prefix)?.lookup(spec),
              current.command == oldCommand,
              current.note == oldNote,
              let replacement = KeyTableSet.defaults.table(.prefix)?.lookup(spec)
        else { return }
        tables.setBinding(table: .prefix, binding: replacement)
    }

    @discardableResult
    public static func save(_ set: KeyTableSet) throws -> URL {
        try HarnessPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(set)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }
}
