import Foundation

/// A copy-mode editing/motion command, dispatched while copy mode is active —
/// tmux's `copy-mode -X <command>` set. Bindings in the `copy-mode` `KeyTable`
/// map keys to these, so copy-mode keys are fully rebindable via
/// `bind-key -T copy-mode <key> <command>`. The copy-mode view (and, later, the
/// in-pane overlay and the attach-window compositor) interpret them.
public enum CopyModeAction: Codable, Sendable, Equatable {
    case cursorLeft, cursorRight, cursorUp, cursorDown
    case nextWord, previousWord
    case startOfLine, endOfLine
    case top, bottom                       // history-top / history-bottom
    case previousPrompt, nextPrompt        // jump between OSC 133 shell-prompt rows
    case pageUp, pageDown, halfPageUp, halfPageDown
    case beginSelection, clearSelection, selectLine, rectangleToggle
    case searchForward, searchBackward, searchAgain, searchReverse
    case copySelection, copySelectionAndCancel
    case copyPipe(String)                  // copy-pipe "<shell command>"
    case paste
    case cancel

    /// tmux copy-mode command name (for `copy-mode -X <name>` / `list-keys`).
    public var tmuxName: String {
        switch self {
        case .cursorLeft: return "cursor-left"
        case .cursorRight: return "cursor-right"
        case .cursorUp: return "cursor-up"
        case .cursorDown: return "cursor-down"
        case .nextWord: return "next-word"
        case .previousWord: return "previous-word"
        case .startOfLine: return "start-of-line"
        case .endOfLine: return "end-of-line"
        case .top: return "history-top"
        case .bottom: return "history-bottom"
        case .previousPrompt: return "previous-prompt"
        case .nextPrompt: return "next-prompt"
        case .pageUp: return "page-up"
        case .pageDown: return "page-down"
        case .halfPageUp: return "halfpage-up"
        case .halfPageDown: return "halfpage-down"
        case .beginSelection: return "begin-selection"
        case .clearSelection: return "clear-selection"
        case .selectLine: return "select-line"
        case .rectangleToggle: return "rectangle-toggle"
        case .searchForward: return "search-forward"
        case .searchBackward: return "search-backward"
        case .searchAgain: return "search-again"
        case .searchReverse: return "search-reverse"
        case .copySelection: return "copy-selection"
        case .copySelectionAndCancel: return "copy-selection-and-cancel"
        case .copyPipe: return "copy-pipe"
        case .paste: return "paste"
        case .cancel: return "cancel"
        }
    }

    /// Parse a tmux copy-mode command name (plus an optional argument for
    /// `copy-pipe`). Returns nil for unknown names.
    public init?(tmuxName name: String, argument: String? = nil) {
        switch name {
        case "cursor-left": self = .cursorLeft
        case "cursor-right": self = .cursorRight
        case "cursor-up": self = .cursorUp
        case "cursor-down": self = .cursorDown
        case "next-word", "next-word-end": self = .nextWord
        case "previous-word": self = .previousWord
        case "start-of-line", "back-to-indentation": self = .startOfLine
        case "end-of-line": self = .endOfLine
        case "history-top", "top-line": self = .top
        case "history-bottom", "bottom-line": self = .bottom
        case "previous-prompt": self = .previousPrompt
        case "next-prompt": self = .nextPrompt
        case "page-up": self = .pageUp
        case "page-down": self = .pageDown
        case "halfpage-up": self = .halfPageUp
        case "halfpage-down": self = .halfPageDown
        case "begin-selection": self = .beginSelection
        case "clear-selection": self = .clearSelection
        case "select-line": self = .selectLine
        case "rectangle-toggle": self = .rectangleToggle
        case "search-forward": self = .searchForward
        case "search-backward": self = .searchBackward
        case "search-again": self = .searchAgain
        case "search-reverse": self = .searchReverse
        case "copy-selection": self = .copySelection
        case "copy-selection-and-cancel", "copy-end-of-line": self = .copySelectionAndCancel
        case "copy-pipe", "copy-pipe-and-cancel": self = .copyPipe(argument ?? "")
        case "paste", "paste-buffer": self = .paste
        case "cancel": self = .cancel
        default: return nil
        }
    }
}
