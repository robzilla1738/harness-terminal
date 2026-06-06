import XCTest
@testable import HarnessOnboarding

/// The onboarding module is deliberately HarnessCore-free, so the fish completion it writes must
/// come from the host's catalog-driven generator via this injection seam — never a second hardcoded
/// command list. These pin the seam's default-and-injected contract.
@MainActor
final class OnboardingEnvironmentTests: XCTestCase {
    override func tearDown() {
        OnboardingEnvironment.fishCompletionScript = { nil }
        super.tearDown()
    }

    func testFishCompletionScriptDefaultsToNilSoTheStepSkipsInIsolation() {
        // Unset by default (preview/test) → the Shell step skips writing fish completion rather than
        // embedding a drift-prone literal.
        OnboardingEnvironment.fishCompletionScript = { nil }
        XCTAssertNil(OnboardingEnvironment.fishCompletionScript())
    }

    func testFishCompletionScriptUsesTheInjectedGenerator() {
        OnboardingEnvironment.fishCompletionScript = { "complete -c harness-cli ..." }
        XCTAssertEqual(OnboardingEnvironment.fishCompletionScript(), "complete -c harness-cli ...")
    }
}
