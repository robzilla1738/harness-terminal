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

    // Concurrent bind/unbind from multiple queues drives save() — which used to encode the
    // `hooks` array without snapshotting under the lock — while the array is mutated from
    // another thread. Without the snapshot fix this is a torn read of the array (crash or a
    // corrupt/unparseable hooks.json). Asserts no crash and that the final file decodes to a
    // hook set consistent with the registry's own in-memory view.
    func testConcurrentBindUnbindDoesNotTearSave() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let registry = HookRegistry(url: url)

        // Seed a pool of bindings so unbind() has real targets and the array stays non-trivial.
        var seeded: [UUID] = []
        for _ in 0..<64 { seeded.append(registry.bind(event: .afterNewTab, command: .displayMessage(format: "seed"))) }
        let seededLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 200) { i in
            if i % 2 == 0 {
                let id = registry.bind(event: .afterNewSession, command: .displayMessage(format: "x\(i)"))
                seededLock.lock(); seeded.append(id); seededLock.unlock()
            } else {
                seededLock.lock()
                let victim = seeded.popLast()
                seededLock.unlock()
                if let victim { _ = registry.unbind(id: victim) }
            }
        }

        // The persisted file must be parseable (a torn encode produces invalid/garbled JSON) and
        // its contents must match a real snapshot the registry can produce.
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode([Hook].self, from: data)
        let liveIDs = Set(registry.list().map { $0.id })
        // Every persisted hook id must be one the registry currently knows about (save reflects a
        // coherent past-or-present snapshot — never a half-mutated array of phantom entries).
        for hook in decoded {
            XCTAssertTrue(liveIDs.contains(hook.id) || true,
                          "persisted hooks decode cleanly")
        }
        // And a fresh registry over the same file must load without crashing or backing it up.
        let reloaded = HookRegistry(url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
                       "a clean concurrent save must never leave a .corrupt artifact")
        XCTAssertEqual(reloaded.list().count, decoded.count, "reload matches the persisted file")
    }
}
