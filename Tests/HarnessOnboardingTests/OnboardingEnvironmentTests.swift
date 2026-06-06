import XCTest
@testable import HarnessOnboarding

/// The onboarding module is deliberately HarnessCore-free, so the fish completion it writes must
/// come from the host's catalog-driven generator via this injection seam — never a second hardcoded
/// command list. These pin the seam's default-and-injected contract.
@MainActor
final class OnboardingEnvironmentTests: XCTestCase {
    // No tearDown override: under strict concurrency a tearDown override is nonisolated (it
    // overrides a nonisolated XCTest method), so it can't touch the MainActor seam — each test
    // restores the seam inline instead.
    func testFishCompletionScriptDefaultsToNilSoTheStepSkipsInIsolation() {
        // Unset by default (preview/test) → the Shell step skips writing fish completion rather than
        // embedding a drift-prone literal.
        OnboardingEnvironment.fishCompletionScript = { nil }
        XCTAssertNil(OnboardingEnvironment.fishCompletionScript())
    }

    func testFishCompletionScriptUsesTheInjectedGenerator() {
        defer { OnboardingEnvironment.fishCompletionScript = { nil } }
        OnboardingEnvironment.fishCompletionScript = { "complete -c harness-cli ..." }
        XCTAssertEqual(OnboardingEnvironment.fishCompletionScript(), "complete -c harness-cli ...")
    }
}
