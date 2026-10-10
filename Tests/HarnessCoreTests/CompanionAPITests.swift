import XCTest
@testable import HarnessCore
final class CompanionAPITests: XCTestCase {
    func testSpecializedMethodsEnforceCapabilitiesExposureAndEffects() throws {
        let capabilities: Set<String> = [DaemonStats.mobileCompanion, DaemonStats.outputSearch]
        XCTAssertThrowsError(try CompanionAPICatalog.validate(name: "device.installKey", arguments: ["publicKey": .string("public")], exposure: .mobile, capabilities: capabilities))
        XCTAssertThrowsError(try CompanionAPICatalog.validate(name: "workspace.close", arguments: ["workspace": .string("id")], exposure: .mobile, capabilities: capabilities, allowWrite: false))
        XCTAssertThrowsError(try CompanionAPICatalog.validate(name: "snapshot.get", arguments: [:], exposure: .mobile, capabilities: []))
        XCTAssertThrowsError(try CompanionAPICatalog.validate(name: "pane.history", arguments: ["count": .string("bad")], exposure: .mobile, capabilities: capabilities))
        XCTAssertThrowsError(try CompanionAPICatalog.validate(name: "snapshot.get", arguments: ["unknown": .bool(true)], exposure: .mobile, capabilities: capabilities))
        try CompanionAPICatalog.validate(name: "pane.history", arguments: ["count": .int(128)], exposure: .mobile, capabilities: capabilities, allowWrite: false)
        XCTAssertEqual(CompanionAPICatalog.method(named: "file.upload")?.access.effect, .write)
        XCTAssertEqual(CompanionAPICatalog.method(named: "snapshot.watch")?.access.effect, .read)
    }
}
