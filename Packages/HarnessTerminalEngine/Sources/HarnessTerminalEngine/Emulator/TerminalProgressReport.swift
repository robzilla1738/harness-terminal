import Foundation

/// A ConEmu progress report (OSC 9;4) — `ESC ] 9 ; 4 ; <state> ; <value> ST`.
/// The terminal-native "program is working" signal: Claude Code 2.0+ keep-alives an
/// indeterminate report across each turn, build tools report determinate percentages.
/// States and semantics match Ghostty/Windows Terminal/ConEmu.
public struct TerminalProgressReport: Equatable, Sendable {
    public enum State: Int, Sendable {
        /// Clear/hide the progress indicator.
        case remove = 0
        /// Normal progress at `value`%.
        case set = 1
        /// Error state (`value` optional).
        case error = 2
        /// Busy with no measurable progress — the "AI is working" pulse. `value` ignored.
        case indeterminate = 3
        /// Paused (`value` optional).
        case paused = 4
    }

    public let state: State
    /// Percentage clamped to 0…100; nil when the report carried none.
    public let value: Int?

    public init(state: State, value: Int?) {
        self.state = state
        self.value = value
    }
}
