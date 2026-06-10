import Foundation

/// Resolves the *effective* bell feedback for the focused surface from the GUI `bellMode` setting
/// and the tmux option bridge (`visual-bell` / `bell-action`). This is the single, pure decision
/// point both the GUI and any future client share — kept free of AppKit so it is unit-testable.
///
/// Precedence (tmux-compatible):
///   1. `bell-action off`/`none` gates **everything** off — the user asked for no bell alerts.
///   2. An explicit `visual-bell` overrides the GUI mode: `off → audible`, `on → visual`,
///      `both → audible+visual`. This lets a migrated `.tmux.conf` drive the behavior.
///   3. Otherwise the GUI `bellMode` decides.
///
/// Unset options are nil (the option store omits unseeded builtins), so a fresh install with no
/// tmux config falls straight through to the GUI default.
public enum BellFeedback: Sendable, Equatable {
    public struct Effect: Sendable, Equatable {
        public var audible: Bool
        public var visual: Bool
        public init(audible: Bool, visual: Bool) {
            self.audible = audible
            self.visual = visual
        }
        /// No feedback at all (neither channel).
        public var isSilent: Bool { !audible && !visual }
    }

    public static func resolve(mode: BellMode, visualBell: String? = nil, bellAction: String? = nil) -> Effect {
        // 1. tmux `bell-action`: off/none suppress entirely. Other values (any/current/other) don't
        //    change the audible/visual split — they scope *which window* alerts, which the GUI
        //    handles via focus, so they pass through here.
        if let bellAction, bellAction == "off" || bellAction == "none" {
            return Effect(audible: false, visual: false)
        }
        // 2. Explicit tmux `visual-bell` overrides the GUI mode.
        switch visualBell {
        case "on", "true", "1": return Effect(audible: false, visual: true)
        case "both": return Effect(audible: true, visual: true)
        case "off", "false", "0": return Effect(audible: true, visual: false)
        default: break // unset / unrecognized → fall through to the GUI mode
        }
        // 3. GUI bellMode.
        switch mode {
        case .off: return Effect(audible: false, visual: false)
        case .audible: return Effect(audible: true, visual: false)
        case .visual: return Effect(audible: false, visual: true)
        case .both: return Effect(audible: true, visual: true)
        }
    }
}
