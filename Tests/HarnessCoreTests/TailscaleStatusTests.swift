import XCTest
@testable import HarnessCore

final class TailscaleStatusTests: XCTestCase {
    func testOnlyRunningLocalAddressesBecomePairingRoutes() throws {
        let ready = try TailscaleStatus.parse(Data(#"{"BackendState":"Running","TailscaleIPs":["100.90.80.70","fd7a:115c:a1e0::1"],"Peer":{"other":{"TailscaleIPs":["100.1.2.3"]}}}"#.utf8))
        XCTAssertEqual(ready.address, "100.90.80.70")
        for state in ["Stopped", "NeedsLogin", "NeedsMachineAuth"] {
            let status = try TailscaleStatus.parse(Data("{\"BackendState\":\"\(state)\",\"TailscaleIPs\":[\"100.90.80.70\"]}".utf8))
            XCTAssertNil(status.address)
            XCTAssertTrue(status.installed)
        }
    }
}
