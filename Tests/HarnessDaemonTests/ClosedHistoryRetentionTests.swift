import Foundation
import HarnessCore
import XCTest
@testable import HarnessDaemonCore

final class ClosedHistoryRetentionTests: XCTestCase {
    func testClosedDiskRetentionSurvivesReopenProtectsActiveAndRefusesCorruptCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hclosed-retention-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("closed.json"), active = UUID().uuidString, closed = UUID().uuidString
        let activeFile = root.appendingPathComponent(active + ".scroll"), closedFile = root.appendingPathComponent(closed + ".scroll")
        try Data("active".utf8).write(to: activeFile); try Data("closed".utf8).write(to: closedFile)
        let owner = ClosedHistoryStore(catalogURL: catalog, historyDirectory: root, protectedSurfaces: [active])
        XCTAssertNil(owner.failure)
        let reopened = ClosedHistoryStore(catalogURL: catalog, historyDirectory: root, protectedSurfaces: [active])
        reopened.maintain(now: .now.addingTimeInterval(15 * 86400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: closedFile.path))
        try Data("recoverable output".utf8).write(to: closedFile)
        let valid = try Data(contentsOf: catalog)
        try Data("invalid catalog".utf8).write(to: catalog)
        let corrupt = ClosedHistoryStore(catalogURL: catalog, historyDirectory: root, protectedSurfaces: [active])
        XCTAssertNotNil(corrupt.failure)
        corrupt.maintain(now: .now.addingTimeInterval(30 * 86400))
        XCTAssertTrue(FileManager.default.fileExists(atPath: closedFile.path))
        XCTAssertEqual(try Data(contentsOf: catalog), Data("invalid catalog".utf8))
        try valid.write(to: catalog)
        corrupt.recover(protectedSurfaces: [active])
        XCTAssertNil(corrupt.failure)
        corrupt.maintain(now: .now.addingTimeInterval(15 * 86400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: closedFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeFile.path))
    }
}
