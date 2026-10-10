import Foundation
import XCTest
@testable import HarnessCore

final class HistoryProtectionTests: XCTestCase {
    #if os(macOS)
    func testRecordsAuthenticateIdentityOrderAndContentWithDistinctNonces() throws {
        let protection = try HistoryProtection(keyMaterial: Data(repeating: 17, count: 32))
        let plain = Data("sensitive terminal output".utf8)
        let first = try protection.seal(plain, identity: "surface:one", sequence: 4)
        let second = try protection.seal(plain, identity: "surface:one", sequence: 4)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(first.range(of: plain) != nil)
        XCTAssertEqual(try protection.open(first, identity: "surface:one", sequence: 4), plain)
        XCTAssertThrowsError(try protection.open(first, identity: "surface:two", sequence: 4))
        XCTAssertThrowsError(try protection.open(first, identity: "surface:one", sequence: 5))
        var corrupt = first; corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try protection.open(corrupt, identity: "surface:one", sequence: 4))
    }
    #endif
    func testUnavailableKeyCannotProducePlaintextRecords() throws {
        let protection = HistoryProtection.unavailable("Keychain is locked")
        XCTAssertEqual(protection.kind, .keyUnavailable)
        XCTAssertThrowsError(try protection.seal(Data("secret".utf8), identity: "run:one", sequence: 1))
    }
}
