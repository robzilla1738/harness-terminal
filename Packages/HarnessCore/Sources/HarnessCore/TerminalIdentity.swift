import Foundation

/// How Harness identifies itself to programs running in a pane — the env var
/// `TERM_PROGRAM`/`TERM_PROGRAM_VERSION` the daemon exports on spawn, and the
/// XTVERSION (`CSI > q`) / secondary-DA (`CSI > c`) replies the engine answers.
///
/// Capability-detecting tools (notably Claude Code) decide whether to enable the
/// Kitty keyboard protocol — which is what makes Shift+Enter insert a newline — by
/// matching `TERM_PROGRAM` against a list of recognized terminals. Harness speaks the
/// same Kitty protocol Ghostty does, so the default **compatible** identity reports
/// `ghostty` and those tools light up immediately. **harness** reports the true name.
///
/// Stored as the `terminal-identity` option (`OptionStore`, persisted in `options.json`),
/// so the daemon (env) and the app (XTVERSION reply) read one value with no drift. The
/// GUI exposes it in Settings ▸ Advanced; `harness-cli set-option terminal-identity …`
/// works for free.
public enum TerminalIdentity {
    /// The `OptionStore` key both sides read.
    public static let optionKey = "terminal-identity"

    public enum Mode: String, Sendable, CaseIterable {
        /// Report a widely-recognized, protocol-compatible identity (`ghostty`) so tools
        /// enable Kitty-keyboard / Shift+Enter out of the box. Default.
        case compatible
        /// Report Harness's true identity. Honest; relies on the tool recognizing Harness
        /// (or trusting the live Kitty probe Harness already answers).
        case harness
    }

    /// Resolve the stored option string to a mode, defaulting to `.compatible`.
    public static func mode(_ raw: String?) -> Mode {
        Mode(rawValue: (raw ?? "").lowercased()) ?? .compatible
    }

    /// The reported identity for a mode.
    /// - `name`: `TERM_PROGRAM` + the XTVERSION name.
    /// - `version`: `TERM_PROGRAM_VERSION` + the XTVERSION version text.
    /// - `daVersion`: the numeric firmware field of the secondary-DA reply (`CSI > 1 ; n ; 0 c`).
    public static func spec(for mode: Mode) -> (name: String, version: String, daVersion: Int) {
        switch mode {
        case .compatible: return ("ghostty", HarnessVersion.short, HarnessVersion.build)
        case .harness: return ("Harness", HarnessVersion.short, HarnessVersion.build)
        }
    }

    /// Convenience: resolve straight from a stored option string.
    public static func spec(forOption raw: String?) -> (name: String, version: String, daVersion: Int) {
        spec(for: mode(raw))
    }
}
