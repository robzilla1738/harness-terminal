import XCTest
@testable import HarnessOnboarding

final class ShellProfileInstallerTests: XCTestCase {
    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-onboarding-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func read(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testFishPathLineQuotesApplicationSupportPathAsOneArgument() {
        let bin = URL(fileURLWithPath: "/Users/test/Library/Application Support/Harness/bin")
        XCTAssertEqual(
            ShellProfileInstaller.pathLine(for: .fish, binDirectory: bin),
            "set -gx PATH '/Users/test/Library/Application Support/Harness/bin' $PATH"
        )
    }

    func testBashAndZshPathLinesKeepPathInsideQuotes() {
        let bin = URL(fileURLWithPath: "/Users/test/Library/Application Support/Harness/bin")
        XCTAssertEqual(
            ShellProfileInstaller.pathLine(for: .zsh, binDirectory: bin),
            "export PATH=\"/Users/test/Library/Application Support/Harness/bin:$PATH\""
        )
        XCTAssertEqual(
            ShellProfileInstaller.pathLine(for: .bash, binDirectory: bin),
            "export PATH=\"/Users/test/Library/Application Support/Harness/bin:$PATH\""
        )
    }

    func testBashBlockSourcesBashrcSoLoginShellsGetShellIntegration() {
        // Harness spawns `$SHELL -l`; a bash LOGIN shell reads `.bash_profile` but NOT `.bashrc`,
        // where the OSC 133 shell integration installs. The bash block must bridge the two or a bash
        // user silently loses prompt marks / the gutter. zsh + fish read one rc for both, so they
        // carry only the PATH line.
        let bin = URL(fileURLWithPath: "/Users/test/Library/Application Support/Harness/bin")
        let bash = ShellProfileInstaller.blockBody(for: .bash, binDirectory: bin)
        XCTAssertTrue(bash.contains(ShellProfileInstaller.pathLine(for: .bash, binDirectory: bin)), "keeps the PATH export")
        XCTAssertTrue(bash.contains("~/.bashrc"), "bridges to .bashrc")
        XCTAssertTrue(bash.contains(". ~/.bashrc"), "sources it, guarded by an existence test")

        XCTAssertEqual(ShellProfileInstaller.blockBody(for: .zsh, binDirectory: bin), ShellProfileInstaller.pathLine(for: .zsh, binDirectory: bin))
        XCTAssertEqual(ShellProfileInstaller.blockBody(for: .fish, binDirectory: bin), ShellProfileInstaller.pathLine(for: .fish, binDirectory: bin))
    }

    func testBashInstallWritesTheBashrcBridgeIntoTheMarkedBlock() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("Library/Application Support/Harness/bin")
        _ = try ShellProfileInstaller.install(.bash, home: home, binDirectory: bin)
        let content = read(home.appendingPathComponent(".bash_profile"))
        XCTAssertTrue(content.contains("# >>> Harness CLI PATH >>>"))
        XCTAssertTrue(content.contains(". ~/.bashrc"), "the installed bash block sources .bashrc")
    }

    func testInstallAppendsOneMarkedBlockAndIsIdempotent() throws {
        let home = try makeHome()
        let bin = home.appendingPathComponent("Library/Application Support/Harness/bin")
        let first = try ShellProfileInstaller.install(.zsh, home: home, binDirectory: bin)
        XCTAssertFalse(first.alreadyConfigured)
        XCTAssertNil(first.backupURL)

        let rc = home.appendingPathComponent(".zshrc")
        let afterFirst = read(rc)
        XCTAssertTrue(afterFirst.contains("# >>> Harness CLI PATH >>>"))
        XCTAssertTrue(afterFirst.contains(bin.path))

        let second = try ShellProfileInstaller.install(.zsh, home: home, binDirectory: bin)
        XCTAssertTrue(second.alreadyConfigured)
        XCTAssertNil(second.backupURL)
        XCTAssertEqual(read(rc), afterFirst)
    }

    func testExistingProfileIsBackedUpBeforeEdit() throws {
        let home = try makeHome()
        let rc = home.appendingPathComponent(".bash_profile")
        try "alias ll='ls -la'\n".write(to: rc, atomically: true, encoding: .utf8)

        let result = try ShellProfileInstaller.install(.bash, home: home)
        XCTAssertNotNil(result.backupURL)
        XCTAssertEqual(read(result.backupURL!), "alias ll='ls -la'\n")
        XCTAssertTrue(read(rc).contains("alias ll='ls -la'"))
        XCTAssertTrue(read(rc).contains("Harness CLI PATH"))
    }

    func testExistingMarkedBlockIsReplacedNotDuplicated() throws {
        let home = try makeHome()
        let rc = home.appendingPathComponent(".config/fish/config.fish")
        try FileManager.default.createDirectory(at: rc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        # >>> Harness CLI PATH >>>
        set -gx PATH '/old/Harness/bin' $PATH
        # <<< Harness CLI PATH <<<
        """.write(to: rc, atomically: true, encoding: .utf8)

        let bin = URL(fileURLWithPath: "/Users/test/Library/Application Support/Harness/bin")
        _ = try ShellProfileInstaller.install(.fish, home: home, binDirectory: bin)
        let content = read(rc)
        XCTAssertFalse(content.contains("/old/Harness/bin"))
        XCTAssertTrue(content.contains("'/Users/test/Library/Application Support/Harness/bin'"))
        XCTAssertEqual(content.components(separatedBy: "# >>> Harness CLI PATH >>>").count - 1, 1)
    }

    func testRelevantProfilesAreTheLoginShellPlusShellsAlreadyInUse() throws {
        let home = try makeHome()
        // A fresh zsh account: only zsh, even though no .zshrc exists yet.
        XCTAssertEqual(ShellProfileInstaller.relevantProfiles(home: home, loginShell: "/bin/zsh").map(\.shell), [.zsh])

        // A fish user who also kept a .bash_profile: fish first, then bash; zsh is left alone.
        try "".write(to: home.appendingPathComponent(".bash_profile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ShellProfileInstaller.relevantProfiles(home: home, loginShell: "/opt/homebrew/bin/fish").map(\.shell),
                       [.fish, .bash])

        // An unknown login shell falls back to zsh, the macOS default.
        XCTAssertEqual(ShellProfileInstaller.relevantProfiles(home: home, loginShell: "/bin/tcsh").map(\.shell), [.zsh, .bash])
    }
}
