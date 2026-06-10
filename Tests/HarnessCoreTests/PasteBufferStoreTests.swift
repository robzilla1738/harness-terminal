import XCTest
@testable import HarnessCore

final class PasteBufferStoreTests: XCTestCase {
    private func tmpURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("harness-buffers-\(UUID().uuidString).json")
    }

    func testAutoNamedBuffersIncrementAndPersist() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PasteBufferStore(url: url)
        XCTAssertEqual(store.set(Data("first".utf8)), "buffer0")
        XCTAssertEqual(store.set(Data("second".utf8)), "buffer1")
        XCTAssertEqual(store.set(Data("named".utf8), name: "scratch"), "scratch")
        XCTAssertEqual(store.list().count, 3)
        store.flush()  // saves are debounced; force the write before reopening
        // Reopening picks up the existing auto index so we don't collide.
        let reopened = PasteBufferStore(url: url)
        XCTAssertEqual(reopened.set(Data("third".utf8)), "buffer2")
    }

    func testReplacingByNameKeepsCountConstant() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PasteBufferStore(url: url)
        store.set(Data("a".utf8), name: "x")
        store.set(Data("b".utf8), name: "x")
        XCTAssertEqual(store.list().count, 1)
        XCTAssertEqual(store.get("x")?.data, Data("b".utf8))
    }

    func testMostRecentReflectsCreatedAt() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PasteBufferStore(url: url)
        store.set(Data("a".utf8), name: "first")
        Thread.sleep(forTimeInterval: 0.005)
        store.set(Data("b".utf8), name: "second")
        XCTAssertEqual(store.mostRecent()?.name, "second")
    }

    func testEvictionRespectsCountLimit() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PasteBufferStore(url: url, configuration: .init(maxBuffers: 3, maxTotalBytes: 1_048_576))
        for i in 0..<10 {
            store.set(Data("buffer-\(i)".utf8))
        }
        XCTAssertEqual(store.list().count, 3, "old buffers must be evicted to honor maxBuffers")
    }

    func testOversizedSetIsRejectedAndPreservesExistingBuffers() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Small byte budget so a single big payload exceeds it.
        let store = PasteBufferStore(url: url, configuration: .init(maxBuffers: 50, maxTotalBytes: 1024))
        XCTAssertEqual(store.set(Data("keep-me".utf8), name: "a"), "a")
        XCTAssertEqual(store.set(Data("and-me".utf8), name: "b"), "b")

        // A buffer larger than the whole budget must be refused — NOT stored, and crucially must
        // not wipe the existing buffers (the old code evicted everything and returned a phantom name).
        let big = Data(repeating: UInt8(ascii: "x"), count: 2048)
        XCTAssertNil(store.set(big, name: "huge"), "an oversized payload is rejected")
        XCTAssertNil(store.get("huge"), "the rejected buffer is not stored")
        XCTAssertEqual(store.get("a")?.data, Data("keep-me".utf8), "existing buffers survive a rejected set")
        XCTAssertEqual(store.get("b")?.data, Data("and-me".utf8))
        XCTAssertEqual(store.list().count, 2)
        store.flush()  // saves are debounced; force the write before reopening

        // And the on-disk file still holds the two buffers (not an empty array).
        let reopened = PasteBufferStore(url: url, configuration: .init(maxBuffers: 50, maxTotalBytes: 1024))
        XCTAssertEqual(reopened.list().count, 2, "persistence was not clobbered by the rejected set")
    }

    func testByteCapEvictsOldestButKeepsTheJustSetBuffer() {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Budget fits ~2 of these 400-byte buffers.
        let store = PasteBufferStore(url: url, configuration: .init(maxBuffers: 50, maxTotalBytes: 1000))
        let payload = Data(repeating: UInt8(ascii: "x"), count: 400) // size is what matters; names distinguish
        store.set(payload, name: "a")
        store.set(payload, name: "b")
        store.set(payload, name: "c") // pushes total to 1200 > 1000 → oldest ("a") evicted

        XCTAssertNil(store.get("a"), "oldest buffer evicted under the byte cap")
        XCTAssertNotNil(store.get("c"), "the just-set buffer is always kept")
        XCTAssertNotNil(store.get("b"))
        XCTAssertFalse(store.list().isEmpty, "the byte cap never empties the store")
    }

    func testDeleteRemovesAndPersists() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PasteBufferStore(url: url)
        store.set(Data("a".utf8), name: "x")
        XCTAssertTrue(store.delete("x"))
        XCTAssertNil(store.get("x"))
        XCTAssertFalse(store.delete("x"))
    }

    func testCorruptBuffersFileIsBackedUpNotDiscarded() throws {
        let url = tmpURL()
        let backup = url.appendingPathExtension("corrupt")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: backup)
        }
        try Data("{ not valid buffers json ".utf8).write(to: url)

        // Unreadable file: the store starts empty but preserves the bad file as `.corrupt`
        // (mirrors hooks/environment/keybindings) instead of letting the next save
        // atomically overwrite the only copy.
        let store = PasteBufferStore(url: url)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the unreadable file is renamed .corrupt")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not valid buffers json ")

        // A normal mutation then writes fresh state without touching the backup.
        store.set(Data("new".utf8), name: "x")
        store.flush()  // saves are debounced; force the write before reloading
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not valid buffers json ")
        XCTAssertEqual(PasteBufferStore(url: url).get("x")?.data, Data("new".utf8))
    }

    func testAbsentBuffersFileStartsEmptyWithoutBackup() throws {
        let url = tmpURL()
        let store = PasteBufferStore(url: url)
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path),
            "a missing file is the normal first run, not corruption"
        )
    }
}
