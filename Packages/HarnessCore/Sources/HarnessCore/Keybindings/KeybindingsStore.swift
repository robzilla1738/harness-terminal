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
        // entry from the file = falling back to default.
        var merged = stored
        for defaultTable in defaults.tableList {
            if var existing = merged.table(defaultTable.id) {
                for binding in defaultTable.bindings where existing.lookup(binding.spec) == nil {
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
