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
        XCTAssertFalse(setup.blocksNavigation)
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

    func testUnansweredPermissionRequestTimesOutAndCanRetry() async throws {
        let setup = OnboardingSetup()
        setup.notificationTimeout = .milliseconds(10)
        setup.notificationRequest = { _ in }
        setup.requestNotifications()
        XCTAssertFalse(setup.blocksNavigation)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(setup.isBusy)
        XCTAssertNotNil(setup.hooksError)
        setup.notificationRequest = { $0(.success(.granted)) }
        setup.requestNotifications()
        XCTAssertEqual(setup.notifications, .granted)
        XCTAssertNil(setup.hooksError)
    }

    func testLeavingPermissionStepIgnoresLateCallbackFromEarlierRequest() {
        let setup = OnboardingSetup()
        var callbacks: [@MainActor @Sendable (Result<NotificationPermission.State, Error>) -> Void] = []
        setup.notificationRequest = { callbacks.append($0) }
        setup.requestNotifications()
        setup.stopWaitingForNotifications()
        XCTAssertFalse(setup.isBusy)
        setup.requestNotifications()
        callbacks[0](.success(.denied))
        XCTAssertTrue(setup.isRequestingNotifications)
        XCTAssertEqual(setup.notifications, .undetermined)
        callbacks[1](.success(.granted))
        XCTAssertFalse(setup.isBusy)
        XCTAssertEqual(setup.notifications, .granted)
    }

    func testLocalInstallsStillBlockNavigation() {
        let setup = OnboardingSetup()
        setup.isInstallingCLI = true
        XCTAssertTrue(setup.blocksNavigation)
        setup.isInstallingCLI = false
        setup.isInstallingHooks = true
        XCTAssertTrue(setup.blocksNavigation)
    }
}
