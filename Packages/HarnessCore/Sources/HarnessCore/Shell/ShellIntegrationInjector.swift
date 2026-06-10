import Foundation

/// Auto-injected shell integration (OSC 133 prompt marks) at spawn — Ghostty's "it just
/// works" behavior, without touching the user's rc files. The daemon owns the spawn
/// environment, so each shell gets its standard injection vehicle:
///
/// - **zsh** — `ZDOTDIR` shim: a directory whose `.zshenv` restores the user's real
///   `ZDOTDIR`, chains to their own `.zshenv`, then sources the integration for
///   interactive shells only.
/// - **bash** — the `--posix` + `$ENV` technique (kitty/Ghostty lineage): POSIX-mode
///   interactive bash reads only `$ENV`, so the shim un-posixes, replays the startup
///   files a normal bash would have read (login files when `HARNESS_BASH_LOGIN` is set,
///   `.bashrc` otherwise), then sources the integration. Known cost, stated loudly:
///   `shopt -q login_shell` reports off inside the pane.
/// - **fish** — `XDG_DATA_DIRS` vendor dir: fish sources
///   `<dir>/fish/vendor_conf.d/*.fish` from every data dir, so prepending ours injects
///   without touching user config.
///
/// Idempotent against a manual `install-shell-integration`: the snippets guard their own
/// re-registration (zsh `add-zsh-hook` dedupes, bash pattern-checks `PROMPT_COMMAND`/`PS1`,
/// fish replaces same-named event functions). Never active for non-interactive shells —
/// each vehicle is interactive-gated by construction AND the shims re-check. Opt out with
/// `set-option shell-integration off` (applies to subsequently spawned panes).
///
/// Bash requires **bash ≥ 4.4**: older bash (notably the stock macOS 3.2) does not read
/// `$ENV` under `--posix` when invoked as `bash`, which would leave the pane in posix mode
/// with NO startup files at all — strictly worse than no injection. The version is probed
/// once per shell path (cached); too-old or unprobeable bash spawns untouched, exactly the
/// Ghostty policy (their automatic bash integration carries the same floor).
public enum ShellIntegrationInjector {
    /// What a spawn must change to carry the injection. `environment` merges over the
    /// inherited process env; `argumentsOverride` replaces the shell's launch arguments
    /// when non-nil. The plan is ALL-or-nothing: a caller whose user `set-environment`
    /// table already defines any of these keys must drop the entire plan — applying
    /// `argumentsOverride` with a foreign value for a plan variable (e.g. bash `--posix`
    /// with the user's own `$ENV`) corrupts the spawn.
    public struct Plan: Sendable, Equatable {
        public var environment: [String: String]
        public var argumentsOverride: [String]?
    }

    /// Build (and lay down on disk, idempotently) the injection for `shellPath`, or nil
    /// for shells without a vehicle (the pane still works; integration is just manual).
    /// `baseEnvironment` is the environment the child would otherwise inherit — the zsh
    /// shim needs the user's original `ZDOTDIR` and fish needs the existing
    /// `XDG_DATA_DIRS` to chain correctly.
    public static func plan(
        shellPath: String,
        baseEnvironment: [String: String],
        home: URL = HarnessPaths.applicationSupport,
        bashVersionProbe: (String) -> (major: Int, minor: Int)? = ShellIntegrationInjector.probeBashVersion
    ) -> Plan? {
        guard let shell = ShellIntegration.Shell.detect(from: shellPath) else { return nil }
        let root = home.appendingPathComponent("shell-integration", isDirectory: true)
        do {
            switch shell {
            case .zsh:
                let script = try writeIntegrationScript(.zsh, root: root)
                let zdotdir = root.appendingPathComponent("zdotdir", isDirectory: true)
                try writeIfChanged(zshShim(scriptPath: script.path), to: zdotdir.appendingPathComponent(".zshenv"))
                var env = ["ZDOTDIR": zdotdir.path]
                if let original = baseEnvironment["ZDOTDIR"], !original.isEmpty {
                    env["HARNESS_ORIG_ZDOTDIR"] = original
                }
                return Plan(environment: env, argumentsOverride: nil)
            case .bash:
                // The --posix + $ENV vehicle needs bash >= 4.4 (see the type doc). Older or
                // unprobeable bash spawns untouched — never half-inject.
                guard let version = bashVersionProbe(shellPath),
                      version.major > 4 || (version.major == 4 && version.minor >= 4)
                else { return nil }
                let script = try writeIntegrationScript(.bash, root: root)
                let shim = root.appendingPathComponent("bash-shim.sh")
                try writeIfChanged(bashShim(scriptPath: script.path), to: shim)
                return Plan(
                    environment: ["ENV": shim.path, "HARNESS_BASH_LOGIN": "1"],
                    // Replaces the profile's `-l`: POSIX-mode non-login interactive bash
                    // reads exactly `$ENV`; the shim replays the login files itself.
                    argumentsOverride: ["--posix"]
                )
            case .fish:
                let dataDir = root.appendingPathComponent("fish-xdg", isDirectory: true)
                let vendorDir = dataDir.appendingPathComponent("fish/vendor_conf.d", isDirectory: true)
                try writeIfChanged(ShellIntegration.script(for: .fish),
                                   to: vendorDir.appendingPathComponent("harness.fish"))
                let existing = baseEnvironment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
                    ?? "/usr/local/share:/usr/share" // the XDG spec default, preserved for other vendors
                return Plan(
                    environment: ["XDG_DATA_DIRS": "\(dataDir.path):\(existing)"],
                    argumentsOverride: nil
                )
            }
        } catch {
            // Injection is best-effort sugar: a full disk / unwritable home must never
            // stop a pane from spawning. The pane just runs without prompt marks.
            return nil
        }
    }

    /// Probe a bash binary's version (`BASH_VERSINFO`), cached per absolute path for the
    /// process lifetime — one short-lived `bash -c printf` per distinct shell path, run
    /// with the same trust as spawning the pane itself. Non-absolute paths and probe
    /// failures return nil (the caller then skips injection).
    /// The cache means a mid-run bash upgrade needs a daemon restart to be re-probed.
    public static func probeBashVersion(at shellPath: String) -> (major: Int, minor: Int)? {
        guard shellPath.hasPrefix("/") else { return nil }
        if let cached = bashVersionCache.value(for: shellPath) { return cached.version }
        let probed = runBashVersionProbe(shellPath)
        bashVersionCache.store(probed, for: shellPath)
        return probed
    }

    private static func runBashVersionProbe(_ shellPath: String) -> (major: Int, minor: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-c", "printf %s \"${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            // The probe runs inside the daemon's spawn path: a pathological "bash" that
            // never exits must not wedge pane creation. 2s is generous for a `printf`;
            // on expiry kill it and skip injection (the nil result is cached too).
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit() // immediate after SIGKILL; reaps the child
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
            guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
            return (major, minor)
        } catch {
            return nil
        }
    }

    /// Lock-guarded probe cache (nil results cached too — a broken bash is broken all run).
    private final class BashVersionCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: (version: (major: Int, minor: Int)?, probed: Bool)] = [:]
        func value(for path: String) -> (version: (major: Int, minor: Int)?, probed: Bool)? {
            lock.lock(); defer { lock.unlock() }
            return values[path]
        }
        func store(_ version: (major: Int, minor: Int)?, for path: String) {
            lock.lock(); values[path] = (version, true); lock.unlock()
        }
    }
    private static let bashVersionCache = BashVersionCache()

    /// The canonical integration script on disk (same location the manual installer
    /// uses, so both paths share one file).
    private static func writeIntegrationScript(_ shell: ShellIntegration.Shell, root: URL) throws -> URL {
        let url = root.appendingPathComponent("harness.\(shell.rawValue)")
        try writeIfChanged(ShellIntegration.script(for: shell), to: url)
        return url
    }

    /// Idempotent write: spawn-time injection runs per pane, so skip the disk write when
    /// the content already matches (the common case after the first spawn).
    private static func writeIfChanged(_ content: String, to url: URL) throws {
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    /// The `.zshenv` shim. zsh re-resolves `$ZDOTDIR` per startup file, so restoring it
    /// here makes `.zprofile`/`.zshrc`/`.zlogin` load from the user's real location.
    static func zshShim(scriptPath: String) -> String {
        """
        # Harness shell-integration shim (auto-injected via ZDOTDIR).
        # Restores your real ZDOTDIR, chains to your own .zshenv, then loads the OSC 133
        # integration for interactive shells only.
        # Opt out: harness-cli set-option shell-integration off
        if [[ -n "${HARNESS_ORIG_ZDOTDIR-}" ]]; then
          export ZDOTDIR="$HARNESS_ORIG_ZDOTDIR"
          unset HARNESS_ORIG_ZDOTDIR
        else
          unset ZDOTDIR
        fi
        if [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]]; then
          builtin source "${ZDOTDIR:-$HOME}/.zshenv"
        fi
        if [[ -o interactive && -f "\(scriptPath)" ]]; then
          builtin source "\(scriptPath)"
        fi
        """
    }

    /// The `$ENV` shim for `bash --posix`. POSIX-mode interactive bash reads only `$ENV`,
    /// so this replays normal startup (login files under `HARNESS_BASH_LOGIN`, otherwise
    /// the interactive rc chain) before loading the integration.
    static func bashShim(scriptPath: String) -> String {
        """
        # Harness shell-integration shim (auto-injected via ENV under `bash --posix`).
        # Replays the startup files a normal bash would have read, then loads the OSC 133
        # integration for interactive shells.
        # Opt out: harness-cli set-option shell-integration off
        builtin set +o posix
        builtin unset ENV
        if [ -n "${HARNESS_BASH_LOGIN-}" ]; then
          builtin unset HARNESS_BASH_LOGIN
          [ -r /etc/profile ] && builtin source /etc/profile
          for __harness_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
            if [ -r "$__harness_rc" ]; then
              builtin source "$__harness_rc"
              break
            fi
          done
          builtin unset __harness_rc
        else
          [ -r /etc/bash.bashrc ] && builtin source /etc/bash.bashrc
          [ -r "$HOME/.bashrc" ] && builtin source "$HOME/.bashrc"
        fi
        case "$-" in
          *i*) [ -r "\(scriptPath)" ] && builtin source "\(scriptPath)" ;;
        esac
        """
    }
}
