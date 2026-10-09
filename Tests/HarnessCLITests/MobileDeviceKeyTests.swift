import Foundation
import XCTest
@testable import HarnessCLI

final class MobileDeviceKeyTests: XCTestCase {
    func testValidEd25519KeyDropsCallerCommentAndKeepsOnlyManagedLabel() throws {
        let blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + Data(repeating: 7, count: 32)
        let line = try MobileDeviceKeys.normalized("ssh-ed25519 \(blob.base64EncodedString()) arbitrary comment")
        XCTAssertTrue(line.hasPrefix("ssh-ed25519 \(blob.base64EncodedString()) harness-mobile-"))
        XCTAssertFalse(line.contains("arbitrary"))
    }
    func testRejectsOptionsEmbeddedNewlinesAndWrongKeyWireType() {
        let blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + Data(repeating: 7, count: 32)
        for input in ["command=evil ssh-ed25519 \(blob.base64EncodedString())", "ssh-ed25519 \(blob.base64EncodedString())\nssh-rsa attacker", "ssh-ed25519 \(Data(repeating: 0, count: 51).base64EncodedString())"] {
            XCTAssertThrowsError(try MobileDeviceKeys.normalized(input))
        }
    }
}
