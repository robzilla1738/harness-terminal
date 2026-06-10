import Foundation

/// The direction/landing of a vi jump-to-char motion (`f`/`F`/`t`/`T`). `forward`/`backward`
/// land *on* the next/previous occurrence; `toForward`/`toBackward` land just *before*/*after* it.
public enum CopyModeJumpKind: String, Codable, Sendable, Equatable {
    case forward, backward, toForward, toBackward

    /// The opposite landing direction, for `jump-reverse` (`,`): a forward jump reverses to a
    /// backward one of the same on/before flavor, and vice-versa.
    public var reversed: CopyModeJumpKind {
        switch self {
        case .forward: return .backward
        case .backward: return .forward
        case .toForward: return .toBackward
        case .toBackward: return .toForward
        }
    }
}

/// A remembered jump (kind + target char) so `jump-again` (`;`) / `jump-reverse` (`,`) can repeat
/// it. Not `Codable` — it's transient runtime state, never persisted.
public struct CopyModeJump: Sendable, Equatable {
    public var kind: CopyModeJumpKind
    public var target: Character
    public init(kind: CopyModeJumpKind, target: Character) {
        self.kind = kind
        self.target = target
    }
}

/// A copy-mode editing/motion command, dispatched while copy mode is active —
/// tmux's `copy-mode -X <command>` set. Bindings in the `copy-mode` `KeyTable`
/// map keys to these, so copy-mode keys are fully rebindable via
/// `bind-key -T copy-mode <key> <command>`. The copy-mode view (and, later, the
/// in-pane overlay and the attach-window compositor) interpret them.
public enum CopyModeAction: Codable, Sendable, Equatable {
    case cursorLeft, cursorRight, cursorUp, cursorDown
    case nextWord, previousWord
    case nextWordEnd                       // end of the next word (vi `e`)
    /// Jump-to-char (vi `f`/`F`/`t`/`T`). The `String?` is the target character: `nil` is the
    /// bindable command form (the front-end captures the next keystroke and re-issues it filled
    /// in); a one-char string performs the jump on the cursor's line.
    case jump(CopyModeJumpKind, String?)
    case jumpAgain                         // repeat the last jump (vi `;`)
    case jumpReverse                       // repeat the last jump, reversed (vi `,`)
    case otherEnd                          // swap selection anchor and cursor (vi `o`)
    case gotoLine(Int)                     // jump to a 1-based line number (tmux `goto-line`)
    case startOfLine, endOfLine
    case backToIndentation                 // first non-blank column of the line (vi `^`)
    case top, bottom                       // history-top / history-bottom
    case topLine, middleLine, bottomLine   // top / middle / bottom of the visible window (vi H/M/L)
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
        case .nextWordEnd: return "next-word-end"
        case let .jump(kind, _):
            switch kind {
            case .forward: return "jump-forward"
            case .backward: return "jump-backward"
            case .toForward: return "jump-to-forward"
            case .toBackward: return "jump-to-backward"
            }
        case .jumpAgain: return "jump-again"
        case .jumpReverse: return "jump-reverse"
        case .otherEnd: return "other-end"
        case .gotoLine: return "goto-line"
        case .startOfLine: return "start-of-line"
        case .endOfLine: return "end-of-line"
        case .backToIndentation: return "back-to-indentation"
        case .top: return "history-top"
        case .bottom: return "history-bottom"
        case .topLine: return "top-line"
        case .middleLine: return "middle-line"
        case .bottomLine: return "bottom-line"
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
        case "next-word": self = .nextWord
        case "previous-word": self = .previousWord
        case "next-word-end": self = .nextWordEnd
        // Harness's word motions are whitespace-delimited, so tmux's `next-space` family (vi
        // big-WORD W/B/E) maps onto the same motions; `word-separators`-aware small-word motions
        // are a deferred refinement.
        case "next-space": self = .nextWord
        case "previous-space": self = .previousWord
        case "next-space-end": self = .nextWordEnd
        // Jump-to-char: the bindable form carries no target (front-end captures the next key);
        // an explicit `argument` (e.g. from a script) fills it in immediately.
        case "jump-forward": self = .jump(.forward, argument)
        case "jump-backward": self = .jump(.backward, argument)
        case "jump-to-forward": self = .jump(.toForward, argument)
        case "jump-to-backward": self = .jump(.toBackward, argument)
        case "jump-again": self = .jumpAgain
        case "jump-reverse": self = .jumpReverse
        case "other-end": self = .otherEnd
        case "goto-line": self = .gotoLine(argument.flatMap { Int($0) } ?? 1)
        case "start-of-line": self = .startOfLine
        case "back-to-indentation": self = .backToIndentation
        case "end-of-line": self = .endOfLine
        case "history-top": self = .top
        case "history-bottom": self = .bottom
        case "top-line": self = .topLine
        case "middle-line": self = .middleLine
        case "bottom-line": self = .bottomLine
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
