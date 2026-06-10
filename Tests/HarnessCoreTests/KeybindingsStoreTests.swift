import XCTest
@testable import HarnessCore

final class KeybindingsStoreTests: XCTestCase {
    private func withTemporaryHarnessHome(_ body: (URL) throws -> Void) throws {
        let previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let root = URL(fileURLWithPath: "/tmp/harness-keybindings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("HARNESS_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    func testCorruptKeybindingsAreBackedUpNotOverwritten() throws {
        try withTemporaryHarnessHome { _ in
            try HarnessPaths.ensureDirectories()
            let url = KeybindingsStore.fileURL
            try Data("{ not valid keybindings json ".utf8).write(to: url)

            // Unreadable file: load() returns the default tables and preserves the bad file as
            // `.corrupt` rather than silently overwriting the user's bindings with defaults.
            let loaded = KeybindingsStore.load()
            XCTAssertFalse(loaded.tableList.isEmpty, "defaults are returned when the file can't decode")

            let backup = url.appendingPathExtension("corrupt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the unreadable file is renamed .corrupt")
            XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not valid keybindings json ")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "load() must not rewrite the original over the corrupt file")
        }
    }

    /// Unbinding a DEFAULT binding must survive save → load. Without a tombstone the
    /// load-time default merge can't tell a deliberate unbind from an uncustomized
    /// default and silently resurrects it on the next launch — contradicting the
    /// documented `unbind-key` workflow.
    func testUnboundDefaultBindingDoesNotResurrectOnReload() throws {
        try withTemporaryHarnessHome { _ in
            try HarnessPaths.ensureDirectories()
            var set = KeybindingsStore.load()
            let spec = KeySpec(key: "c") // default: prefix c → newWindow
            XCTAssertNotNil(set.table(.prefix)?.lookup(spec), "precondition: the default exists")

            set.removeBinding(table: .prefix, spec: spec)
            try KeybindingsStore.save(set)

            let reloaded = KeybindingsStore.load()
            XCTAssertNil(reloaded.table(.prefix)?.lookup(spec),
                         "an explicitly unbound default must stay unbound across reloads")
            // Other defaults are untouched.
            XCTAssertNotNil(reloaded.table(.prefix)?.lookup(KeySpec(key: "x")))
        }
    }

    /// Re-binding a previously unbound spec clears its tombstone — and the new binding
    /// (not the default) survives the reload merge.
    func testRebindingClearsTheTombstone() throws {
        try withTemporaryHarnessHome { _ in
            try HarnessPaths.ensureDirectories()
            var set = KeybindingsStore.load()
            let spec = KeySpec(key: "c")
            set.removeBinding(table: .prefix, spec: spec)
            set.setBinding(table: .prefix, binding: Binding(spec: spec, command: .killPane, note: "custom"))
            try KeybindingsStore.save(set)

            let reloaded = KeybindingsStore.load()
            XCTAssertEqual(reloaded.table(.prefix)?.lookup(spec)?.command, .killPane)
            XCTAssertEqual(reloaded.table(.prefix)?.isDisabled(spec), false)
        }
    }

    /// Old-format files (no `disabledSpecs` key) must keep decoding — and a table with no
    /// tombstones must encode without the key, so untouched user files stay byte-stable.
    func testOldFormatFilesDecodeAndTombstoneKeyIsOmittedWhenEmpty() throws {
        let json = #"{"tables":[{"id":"prefix","bindings":[]}]}"#
        let decoded = try JSONDecoder().decode(KeyTableSet.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.table(.prefix)?.disabledSpecs, [])

        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("disabledSpecs"),
                       "no tombstones → no key, keeping existing files stable")
    }

    func testAbsentKeybindingsFileSeedsDefaults() throws {
        try withTemporaryHarnessHome { _ in
            // No file present at all → defaults are returned and best-effort seeded (this is the
            // normal first-run path and must NOT produce a `.corrupt` backup).
            let loaded = KeybindingsStore.load()
            XCTAssertFalse(loaded.tableList.isEmpty)
            let backup = KeybindingsStore.fileURL.appendingPathExtension("corrupt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    func testStoredPrefixDefaultsKeepTabWorkspaceBindingsAndMergeSessionKeys() throws {
        try withTemporaryHarnessHome { _ in
            var prefix = KeyTable(id: .prefix, bindings: [
                Binding(spec: KeySpec(key: "n"), command: .nextWindow, note: "Next tab"),
                Binding(spec: KeySpec(key: "p"), command: .previousWindow, note: "Previous tab"),
            ])
            for index in 0 ... 9 {
                prefix.set(Binding(spec: KeySpec(key: String(index)), command: .selectWorkspace(index: index), note: "Workspace \(index)"))
            }
            try KeybindingsStore.save(KeyTableSet(tables: [prefix]))

            let loaded = KeybindingsStore.load()
            let loadedPrefix = try XCTUnwrap(loaded.table(.prefix))
            XCTAssertEqual(loadedPrefix.lookup(KeySpec(key: "n"))?.command, .nextWindow)
            XCTAssertEqual(loadedPrefix.lookup(KeySpec(key: "p"))?.command, .previousWindow)
            XCTAssertEqual(loadedPrefix.lookup(KeySpec(key: "("))?.command, .previousSession)
            XCTAssertEqual(loadedPrefix.lookup(KeySpec(key: ")"))?.command, .nextSession)
            for index in 0 ... 9 {
                XCTAssertEqual(loadedPrefix.lookup(KeySpec(key: String(index)))?.command, .selectWorkspace(index: index))
            }
        }
    }

    func testCustomPrefixBindingsAreNotMigrated() throws {
        try withTemporaryHarnessHome { _ in
            var stored = KeyTableSet.defaults
            stored.setBinding(table: .prefix, binding: Binding(spec: KeySpec(key: "n"), command: .nextWindow, note: "Custom next tab"))
            try KeybindingsStore.save(stored)

            let loaded = KeybindingsStore.load()
            XCTAssertEqual(loaded.table(.prefix)?.lookup(KeySpec(key: "n"))?.command, .nextWindow)
            XCTAssertEqual(loaded.table(.prefix)?.lookup(KeySpec(key: "n"))?.note, "Custom next tab")
        }
    }
}
