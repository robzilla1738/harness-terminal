import Foundation

public struct SettingsImportChange: Codable, Sendable {
    public var key: String
    public var before: Data?
    public var after: Data?
    public var replacesCustomization: Bool
    public var title: String {
        key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
    public var summary: String {
        let old = before.map { String(decoding: $0, as: UTF8.self) } ?? "Default"
        let new = after.map { String(decoding: $0, as: UTF8.self) } ?? "Default"
        return "\(String(old.prefix(70))) → \(String(new.prefix(70)))"
    }
}

public struct SettingsImport: Codable, Sendable {
    public var changes: [SettingsImportChange]
    public static var backupURL: URL { HarnessPaths.applicationSupport.appendingPathComponent("last-config-import.json") }

    public init(current: HarnessSettings, imported: ImportedTerminalConfig) throws {
        var proposed = current
        proposed.applyImportedConfig(imported)
        let before = try Self.values(current), after = try Self.values(proposed), defaults = try Self.values(HarnessSettings())
        changes = try Set(before.keys).union(after.keys).sorted().compactMap { key in
            let old = try Self.data(before[key]), new = try Self.data(after[key])
            guard old != new else { return nil }
            let wasCustomized = old != (try Self.data(defaults[key]))
            return SettingsImportChange(key: key, before: old, after: new, replacesCustomization: key == "paletteShortcuts" || wasCustomized)
        }
    }

    private static func values(_ settings: HarnessSettings) throws -> [String: Any] {
        guard let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any] else {
            throw SetupError.invalid("Could not read settings for import.")
        }
        return values
    }
    private static func data(_ value: Any?) throws -> Data? {
        try value.map { try JSONSerialization.data(withJSONObject: $0, options: [.fragmentsAllowed, .sortedKeys]) }
    }

    public func applying(to settings: HarnessSettings, selected: Set<String>) throws -> HarnessSettings {
        var values = try Self.values(settings)
        for change in changes where selected.contains(change.key) || change.key == "importedConfigSignature" {
            values[change.key] = try change.after.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
        return try JSONDecoder().decode(HarnessSettings.self, from: JSONSerialization.data(withJSONObject: values))
    }

    public func saveBackup(selected: Set<String>) throws {
        var backup = self
        backup.changes = changes.filter { selected.contains($0.key) || $0.key == "importedConfigSignature" }
        let data = try JSONEncoder().encode(backup), prior = try PrivateFile.read(Self.backupURL)
        _ = try PrivateFile.replace(Self.backupURL, data: data, expected: prior, backup: true)
    }

    /// Apply only reviewed fields to the exact file used for the preview. Unknown
    /// fields and daemon-owned sections stay intact; a concurrent edit aborts.
    @discardableResult
    public func applyFile(at url: URL, expected: Data?, selected: Set<String>) throws -> URL? {
        guard !selected.isEmpty, selected.isSubset(of: Set(changes.map(\.key))) else {
            throw SetupError.invalid("Select supported fields from the import preview.")
        }
        var values = try expected.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard values != nil else { throw SetupError.invalid("The settings file is not a JSON object.") }
        for change in changes where selected.contains(change.key) || change.key == "importedConfigSignature" {
            let current = try Self.data(values?[change.key])
            // Absent persisted defaults are equivalent to the preview's default.
            if current != nil, current != change.before { throw SetupError.invalid("Settings changed since this import preview. Preview again.") }
            values?[change.key] = try change.after.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
        return try PrivateFile.replace(url, data: JSONSerialization.data(withJSONObject: values!, options: [.sortedKeys]), expected: expected, backup: true)
    }

    public func undo(in settings: HarnessSettings) throws -> HarnessSettings {
        var values = try Self.values(settings)
        for change in changes where try Self.data(values[change.key]) == change.after {
            values[change.key] = try change.before.map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
        return try JSONDecoder().decode(HarnessSettings.self, from: JSONSerialization.data(withJSONObject: values))
    }
}
