import XCTest
@testable import HarnessOnboarding

@MainActor
final class OnboardingSetupTests: XCTestCase {
    func testPermissionRequestIsSingleFlightAndDoesNotInstallHooks() {
        let setup = OnboardingSetup()
        var requests = 0
        var completion: (@MainActor @Sendable (Result<NotificationPermission.State, Error>) -> Void)?
        setup.notificationRequest = { callback in requests += 1; completion = callback }
        setup.agents = [.init(id: "test", displayName: "Test", hooksInstalled: false)]
        setup.requestNotifications()
        setup.requestNotifications()
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(setup.isBusy)
        completion?(.success(.denied))
        XCTAssertFalse(setup.isBusy)
        XCTAssertFalse(setup.isInstallingHooks)
        XCTAssertEqual(setup.notifications, .denied)
        XCTAssertEqual(setup.pendingHookAgents.count, 1)
    }

    func testPermissionFailureIsVisibleAndCanBeRetried() {
        let setup = OnboardingSetup()
        setup.notificationRequest = { $0(.failure(CocoaError(.featureUnsupported))) }
        setup.requestNotifications()
        XCTAssertNotNil(setup.hooksError)
        XCTAssertFalse(setup.isBusy)
        setup.notificationRequest = { $0(.success(.granted)) }
        setup.requestNotifications()
        XCTAssertNil(setup.hooksError)
        XCTAssertEqual(setup.notifications, .granted)
    }
}
