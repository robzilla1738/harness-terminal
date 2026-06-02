import XCTest
@testable import HarnessCore

final class EndpointTests: XCTestCase {
    func testCodableRoundTripUnix() throws {
        let endpoint = Endpoint.unix(path: "/tmp/harness.sock")
        let data = try JSONEncoder().encode(endpoint)
        XCTAssertEqual(try JSONDecoder().decode(Endpoint.self, from: data), endpoint)
    }

    func testCodableRoundTripTCP() throws {
        let endpoint = Endpoint.tcp(host: "example.com", port: 4040)
        let data = try JSONEncoder().encode(endpoint)
        XCTAssertEqual(try JSONDecoder().decode(Endpoint.self, from: data), endpoint)
    }

    func testLocalControlSocketIsUnix() {
        guard case .unix = Endpoint.localControlSocket else {
            return XCTFail("local control socket should be a Unix endpoint")
        }
    }

    func testTCPConnectIsNotYetSupported() {
        XCTAssertThrowsError(try EndpointConnector.connect(.tcp(host: "127.0.0.1", port: 1))) { error in
            guard case EndpointError.notYetSupported = error else {
                return XCTFail("expected .notYetSupported, got \(error)")
            }
        }
    }

    func testUnixConnectRejectsOverlongPath() {
        let tooLong = "/" + String(repeating: "a", count: HarnessPaths.maxSocketPathLength + 10)
        XCTAssertThrowsError(try EndpointConnector.connect(.unix(path: tooLong))) { error in
            guard case EndpointError.pathTooLong = error else {
                return XCTFail("expected .pathTooLong, got \(error)")
            }
        }
    }
}
