import Foundation
import XCTest
@testable import HarnessRemoteProtocol

final class RemotePairingCodeTests: XCTestCase {
    private var info: RemotePairingInfo {
        RemotePairingInfo(host: "studio.local", username: "person", fingerprint: "SHA256:" + Data(repeating: 7, count: 32).base64EncodedString().dropLast(), executablePath: "/Applications/Harness Preview.app/Contents/MacOS/harness-cli")
    }

    func testLinkAndExistingJSONPreserveExactPublicMetadata() throws {
        let link = try info.connectionURL()
        XCTAssertEqual(try RemotePairingInfo.parseConnectionCode(link.absoluteString), info)
        XCTAssertEqual(try RemotePairingInfo.parseConnectionCode(String(decoding: JSONEncoder().encode(info), as: UTF8.self)), info)
        var ipv6 = info
        ipv6.host = "fd00::1234"
        ipv6.executablePath = "/home/person/a&b/ハーネス"
        XCTAssertEqual(try RemotePairingInfo.parseConnectionCode(ipv6.connectionURL().absoluteString), ipv6)
    }

    func testRejectsAmbiguousForeignAndMalformedLinks() throws {
        let valid = try info.connectionURL().absoluteString
        for source in [valid + "&host=attacker", valid + "#fragment", valid + "&password=secret",
                       valid.replacingOccurrences(of: "v=1", with: "v=2"),
                       valid.replacingOccurrences(of: "harness://", with: "https://"),
                       valid.replacingOccurrences(of: "studio.local", with: "bad%0Ahost"),
                       valid.replacingOccurrences(of: "port=22", with: "port=999999"),
                       "harness://connect", String(repeating: "x", count: 16_385)] {
            XCTAssertThrowsError(try RemotePairingInfo.parseConnectionCode(source), source)
        }
    }
}
