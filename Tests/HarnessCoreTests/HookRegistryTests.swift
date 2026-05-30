import XCTest
@testable import HarnessCore

final class HookRegistryTests: XCTestCase {
    private func tempURL() -> URL {
        URL(fileURLWithPath: "/tmp/harness-hooks-\(UUID().uuidString.prefix(8)).json")
    }

    func testBindPersistsAndReloads() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = HookRegistry(url: url)
        _ = registry.bind(event: .afterNewTab, command: .displayMessage(format: "hi"))
        // A fresh registry over the same file must see the persisted binding.
        let reloaded = HookRegistry(url: url)
        XCTAssertEqual(reloaded.list(event: .afterNewTab).count, 1)
    }

    func testCorruptHooksFileIsBackedUpNotDiscarded() throws {
        let url = tempURL()
        let backup = url.appendingPathExtension("corrupt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backup)
        }
        try Data("{ this is not valid json".utf8).write(to: url)
        let registry = HookRegistry(url: url)
        // Corrupt file → start empty, but preserve the bad file as `.corrupt` for recovery
        // rather than silently discarding the user's bindings.
        XCTAssertTrue(registry.list().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path),
                      "expected corrupt hooks.json to be preserved as .corrupt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "expected the unreadable hooks.json to be moved aside")
    }

    func testAbsentHooksFileStartsEmptySilently() {
        let url = tempURL()
        let backup = url.appendingPathExtension("corrupt")
        let registry = HookRegistry(url: url)
        XCTAssertTrue(registry.list().isEmpty)
        // No file at all is the normal first-run case — must not create a .corrupt artifact.
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}
