import XCTest
@testable import HarnessCore

/// Pure coverage of the spawn-time injection plans: per-shell vehicles, env chaining,
/// shim contents, and the no-vehicle fallbacks. The live end-to-end (marks actually
/// appearing, user rc still sourced) runs in `HarnessDaemonTests/ShellIntegrationInjectionTests`.
final class ShellIntegrationInjectorTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inject-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testZshPlanUsesZdotdirShimAndPreservesOriginal() throws {
        let plan = try XCTUnwrap(ShellIntegrationInjector.plan(
            shellPath: "/bin/zsh", baseEnvironment: ["ZDOTDIR": "/Users/me/dotfiles/zsh"], home: home))
        XCTAssertNil(plan.argumentsOverride, "zsh keeps its login arguments")
        let zdotdir = try XCTUnwrap(plan.environment["ZDOTDIR"])
        XCTAssertEqual(plan.environment["HARNESS_ORIG_ZDOTDIR"], "/Users/me/dotfiles/zsh")

        let shim = try String(contentsOf: URL(fileURLWithPath: zdotdir).appendingPathComponent(".zshenv"),
                              encoding: .utf8)
        XCTAssertTrue(shim.contains("HARNESS_ORIG_ZDOTDIR"), "shim restores the user's real ZDOTDIR")
        XCTAssertTrue(shim.contains(".zshenv"), "shim chains to the user's own .zshenv")
        XCTAssertTrue(shim.contains("-o interactive"), "integration loads for interactive shells only")
        // The shim sources the canonical script, which must exist and carry the OSC 133 marks.
        let scriptPath = home.appendingPathComponent("shell-integration/harness.zsh")
        XCTAssertTrue(shim.contains(scriptPath.path))
        let script = try String(contentsOf: scriptPath, encoding: .utf8)
        XCTAssertTrue(script.contains("133;A"))
    }

    func testZshPlanWithoutOriginalZdotdirOmitsTheChainVariable() throws {
        let plan = try XCTUnwrap(ShellIntegrationInjector.plan(
            shellPath: "zsh", baseEnvironment: [:], home: home))
        XCTAssertNil(plan.environment["HARNESS_ORIG_ZDOTDIR"],
                     "no original ZDOTDIR → the shim falls back to $HOME")
        XCTAssertNotNil(plan.environment["ZDOTDIR"])
    }

    func testBashPlanSwapsLoginForPosixAndReplaysStartup() throws {
        let plan = try XCTUnwrap(ShellIntegrationInjector.plan(
            shellPath: "/bin/bash", baseEnvironment: [:], home: home,
            bashVersionProbe: { _ in (5, 2) }))
        XCTAssertEqual(plan.argumentsOverride, ["--posix"],
                       "POSIX-mode interactive bash reads exactly $ENV — the injection vehicle")
        XCTAssertEqual(plan.environment["HARNESS_BASH_LOGIN"], "1")
        let shimPath = try XCTUnwrap(plan.environment["ENV"])
        let shim = try String(contentsOf: URL(fileURLWithPath: shimPath), encoding: .utf8)
        XCTAssertTrue(shim.contains("set +o posix"), "shim un-posixes before user files run")
        XCTAssertTrue(shim.contains(".bash_profile"), "login files replayed (the -l it replaced)")
        XCTAssertTrue(shim.contains(".bashrc"), "interactive rc replayed for the non-login case")
        XCTAssertTrue(shim.contains("*i*"), "integration gated on interactivity")
    }

    func testFishPlanPrependsVendorDirAndPreservesExistingDataDirs() throws {
        let plan = try XCTUnwrap(ShellIntegrationInjector.plan(
            shellPath: "/opt/homebrew/bin/fish",
            baseEnvironment: ["XDG_DATA_DIRS": "/custom/share"], home: home))
        XCTAssertNil(plan.argumentsOverride)
        let dirs = try XCTUnwrap(plan.environment["XDG_DATA_DIRS"])
        XCTAssertTrue(dirs.hasSuffix(":/custom/share"), "existing data dirs preserved after ours")
        let base = String(dirs.split(separator: ":")[0])
        let vendored = URL(fileURLWithPath: base).appendingPathComponent("fish/vendor_conf.d/harness.fish")
        let script = try String(contentsOf: vendored, encoding: .utf8)
        XCTAssertTrue(script.contains("133;A"))
        // vendor_conf.d runs for EVERY fish (scripts, `fish -c`) — the snippet must gate
        // itself; `exit` in a sourced file skips the rest of the file.
        XCTAssertTrue(script.contains("status is-interactive; or exit"),
                      "fish snippet must be interactive-gated")
    }

    func testFishPlanUsesXDGSpecDefaultWhenUnset() throws {
        let plan = try XCTUnwrap(ShellIntegrationInjector.plan(
            shellPath: "fish", baseEnvironment: [:], home: home))
        XCTAssertTrue(try XCTUnwrap(plan.environment["XDG_DATA_DIRS"])
            .hasSuffix(":/usr/local/share:/usr/share"), "the spec default keeps other vendors visible")
    }

    func testUnknownShellGetsNoPlan() {
        XCTAssertNil(ShellIntegrationInjector.plan(shellPath: "/usr/bin/nu", baseEnvironment: [:], home: home))
        XCTAssertNil(ShellIntegrationInjector.plan(shellPath: "", baseEnvironment: [:], home: home))
    }

    /// Old bash (the stock macOS 3.2) doesn't read `$ENV` under `--posix` when invoked as
    /// `bash` — half-injecting would strip the user's startup files. No plan below 4.4;
    /// 4.4 itself is the floor (the Ghostty policy).
    func testBashBelowFloorGetsNoPlan() {
        XCTAssertNil(ShellIntegrationInjector.plan(
            shellPath: "/bin/bash", baseEnvironment: [:], home: home,
            bashVersionProbe: { _ in (3, 2) }))
        XCTAssertNil(ShellIntegrationInjector.plan(
            shellPath: "/bin/bash", baseEnvironment: [:], home: home,
            bashVersionProbe: { _ in (4, 3) }))
        XCTAssertNil(ShellIntegrationInjector.plan(
            shellPath: "/bin/bash", baseEnvironment: [:], home: home,
            bashVersionProbe: { _ in nil }))
        XCTAssertNotNil(ShellIntegrationInjector.plan(
            shellPath: "/bin/bash", baseEnvironment: [:], home: home,
            bashVersionProbe: { _ in (4, 4) }))
    }

    func testPlanIsIdempotentOnDisk() throws {
        _ = ShellIntegrationInjector.plan(shellPath: "zsh", baseEnvironment: [:], home: home)
        let shimURL = home.appendingPathComponent("shell-integration/zdotdir/.zshenv")
        let firstStamp = try FileManager.default.attributesOfItem(atPath: shimURL.path)[.modificationDate] as? Date
        // A second spawn re-plans without rewriting unchanged files.
        _ = ShellIntegrationInjector.plan(shellPath: "zsh", baseEnvironment: [:], home: home)
        let secondStamp = try FileManager.default.attributesOfItem(atPath: shimURL.path)[.modificationDate] as? Date
        XCTAssertEqual(firstStamp, secondStamp, "unchanged shim is not rewritten per spawn")
    }
}
