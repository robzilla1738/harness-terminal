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

    func testDeleteRemovesAndPersists() throws {
        let url = tmpURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PasteBufferStore(url: url)
        store.set(Data("a".utf8), name: "x")
        XCTAssertTrue(store.delete("x"))
        XCTAssertNil(store.get("x"))
        XCTAssertFalse(store.delete("x"))
    }
}
