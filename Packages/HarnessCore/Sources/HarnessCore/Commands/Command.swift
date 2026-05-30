import Foundation

/// Canonical action vocabulary for Harness. Every keystroke binding, CLI
/// subcommand, command-palette entry, hook firing, and `:` prompt entry
/// resolves to a `Command`. The executor (`CommandExecutor`) is the single
/// dispatch point that translates a `Command` into an IPC request, a UI
/// operation, or a composition of both.
///
/// `Command` values are `Codable` so they round-trip through the keybindings
/// file (`keybindings.json`), agent hooks, and remote scripting clients
/// without ad-hoc string serialization.
public indirect enum Command: Codable, Sendable, Equatable {
    // MARK: Pane operations
    case splitWindow(direction: SplitDirection)
    case killPane
    case zoomPane
    case selectPane(target: PaneTarget)
    case swapPane(target: PaneTarget)
    case resizePane(direction: ResizeDirection, amount: Int)
    case markPane(set: Bool)                       // select-pane -m / -M
    case joinPane(direction: SplitDirection)       // join-pane -h/-v (marked → active)
    case synchronizePanes(set: Bool?)              // synchronize-panes [on|off] (nil = toggle)
    case displayPanes                              // display-panes (overlay numbers; digit jumps)

    // MARK: Tab / window operations
    case newWindow                                 // new-window
    case killWindow                                // kill-window
    case renameWindow(newName: String?)            // rename-window [-N name]
    case nextWindow
    case previousWindow
    case selectWindow(index: Int)                  // select-window -t :<n>
    case moveWindow(toIndex: Int)                  // move-window -t :<n> (reorder within session)
    case swapWindow(withIndex: Int)                // swap-window -t :<n> (swap active tab with tab n)

    // MARK: Session / workspace operations
    case newSession(name: String?)
    case killSession
    case renameSession(newName: String?)
    case selectWorkspace(index: Int)               // workspace 0..9
    case nextWorkspace
    case previousWorkspace

    // MARK: Modes
    case copyMode                                  // toggle copy mode
    case copyModeCommand(CopyModeAction)           // copy-mode -X <action> (in-mode motion/selection)
    case detachClient                              // detach the calling client
    case reattachSurface                           // re-grab a surface released to headless
    case jumpToPreviousPrompt                      // scroll to the previous OSC 133 shell prompt
    case jumpToNextPrompt                          // scroll to the next OSC 133 shell prompt

    // MARK: Scripting
    case sendKeys(keys: [String])
    case displayMessage(format: String)
    case runShell(shellCommand: String, captureToBuffer: Bool)
    case ifShell(condition: String, then: Command, otherwise: Command?)   // if-shell

    // MARK: Bindings + config
    case bindKey(table: String, spec: String, command: Command, repeatable: Bool)
    case unbindKey(table: String, spec: String)
    case listKeys(table: String?)
    case sourceConfig                              // re-import terminal config
    case reloadKeybindings                         // re-read keybindings.json

    // MARK: Composition
    case sequence([Command])                       // a ; b ; c

    // MARK: Diagnostics
    case showCheatsheet

    // MARK: Phase 4 — layouts and advanced pane ops
    case selectLayout(name: String)                // select-layout tiled / main-vertical / …
    case nextLayout
    case previousLayout
    case rotateWindow(forward: Bool)               // rotate-window [-D]
    case breakPane                                 // break-pane
    case respawnPane(keepHistory: Bool)            // respawn-pane [-k]
    case movePane(direction: SplitDirection, source: TargetSpec)  // move-pane -s <src> [-h|-v]
    case renumberWindows                           // move-window -r — renumber tabs contiguously

    // MARK: Phase 6 — command completeness
    case lastWindow                                // last-window (MRU tab in the session)
    case sendPrefix                                // send-prefix (send the prefix key to the pane)
    case sourceFile(path: String)                  // source-file <path> (run a file of commands)
    case commandPrompt(prompts: [String], template: String)  // command-prompt -p … "<cmd with %%>"
    case confirmBefore(prompt: String?, command: Command)    // confirm-before -p "…" "<cmd>"
    case choose(scope: ChooseScope)                // choose-tree / choose-session / choose-window / …
    case pipePane(shellCommand: String?)           // pipe-pane "<cmd>" (nil → toggle off)

    // MARK: Phase 7 — server admin & integration
    case lockClient                                // lock-client / lock-session
    case clockMode                                 // clock-mode
    /// `switch-client -T <table>`: resolve the next key press in `<table>` (client-local
    /// state — builds modal/multi-key bindings on top of the prefix). One-shot, like tmux.
    case switchClientTable(table: String)          // switch-client -T <table>
    case linkWindow(targetSessionName: String)     // link-window -t <session>
    case unlinkWindow                              // unlink-window
    case displayPopup(command: String?)            // display-popup [-E <command>]
    case displayMenu(items: [MenuItem])            // display-menu -T title <name> <key> <command> …

    // MARK: Targeting
    /// Run `command` as if the client's focus were `spec`'s resolved target
    /// (tmux's universal `-t session:window.pane`). Resolved centrally in
    /// `CommandIPCTranslator` so every front-end applies the same addressing.
    case targeted(TargetSpec, Command)

    public enum PaneTarget: String, Codable, Sendable, Equatable {
        case left, right, up, down
        case next, previous, last
    }

    public enum ChooseScope: String, Codable, Sendable, Equatable {
        case tree, session, window, buffer, client
    }

    public struct MenuItem: Codable, Sendable, Equatable {
        public var title: String
        public var key: String?
        public var command: Command
        public init(title: String, key: String? = nil, command: Command) {
            self.title = title
            self.key = key
            self.command = command
        }
    }
}

extension Command {
    /// A short, human-readable identifier shown in `list-keys`, command
    /// palette, and `display-message`. Not necessarily a round-trippable form.
    public var shortDescription: String {
        switch self {
        case let .splitWindow(direction): return "split-window -\(direction == .horizontal ? "v" : "h")"
        case .killPane: return "kill-pane"
        case .zoomPane: return "zoom-pane"
        case let .selectPane(target): return "select-pane \(target.rawValue)"
        case let .swapPane(target): return "swap-pane \(target.rawValue)"
        case let .resizePane(direction, amount): return "resize-pane -\(direction.rawValue.prefix(1).uppercased()) \(amount)"
        case let .markPane(set): return set ? "select-pane -m" : "select-pane -M"
        case let .joinPane(direction): return "join-pane -\(direction == .horizontal ? "v" : "h")"
        case let .synchronizePanes(set): return "synchronize-panes\(set.map { $0 ? " on" : " off" } ?? "")"
        case .displayPanes: return "display-panes"
        case .newWindow: return "new-window"
        case .killWindow: return "kill-window"
        case let .renameWindow(name): return "rename-window\(name.map { " \($0)" } ?? "")"
        case .nextWindow: return "next-window"
        case .previousWindow: return "previous-window"
        case let .selectWindow(index): return "select-window -t :\(index)"
        case let .moveWindow(index): return "move-window -t :\(index)"
        case let .swapWindow(index): return "swap-window -t :\(index)"
        case let .newSession(name): return "new-session\(name.map { " -s \($0)" } ?? "")"
        case .killSession: return "kill-session"
        case let .renameSession(name): return "rename-session\(name.map { " \($0)" } ?? "")"
        case let .selectWorkspace(index): return "select-workspace \(index)"
        case .nextWorkspace: return "next-workspace"
        case .previousWorkspace: return "previous-workspace"
        case .copyMode: return "copy-mode"
        case let .copyModeCommand(action):
            if case let .copyPipe(cmd) = action { return "copy-mode -X copy-pipe '\(cmd)'" }
            return "copy-mode -X \(action.tmuxName)"
        case .detachClient: return "detach-client"
        case .reattachSurface: return "reattach-surface"
        case .jumpToPreviousPrompt: return "jump-previous-prompt"
        case .jumpToNextPrompt: return "jump-next-prompt"
        case let .sendKeys(keys): return "send-keys \(keys.joined(separator: " "))"
        case let .displayMessage(format): return "display-message \(format)"
        case let .runShell(cmd, capture): return "run-shell \(capture ? "-b " : "")'\(cmd)'"
        case let .ifShell(condition, then, otherwise):
            return "if-shell '\(condition)' '\(then.shortDescription)'" + (otherwise.map { " '\($0.shortDescription)'" } ?? "")
        case let .bindKey(table, spec, command, repeatable): return "bind-key \(repeatable ? "-r " : "")-T \(table) \(spec) \(command.shortDescription)"
        case let .unbindKey(table, spec): return "unbind-key -T \(table) \(spec)"
        case let .listKeys(table): return "list-keys\(table.map { " -T \($0)" } ?? "")"
        case .sourceConfig: return "source-config"
        case .reloadKeybindings: return "reload-keybindings"
        case let .sequence(commands): return commands.map(\.shortDescription).joined(separator: " ; ")
        case .showCheatsheet: return "show-cheatsheet"
        case let .selectLayout(name): return "select-layout \(name)"
        case .nextLayout: return "next-layout"
        case .previousLayout: return "previous-layout"
        case let .rotateWindow(forward): return forward ? "rotate-window" : "rotate-window -D"
        case .breakPane: return "break-pane"
        case let .respawnPane(keep): return keep ? "respawn-pane" : "respawn-pane -k"
        case let .movePane(direction, source):
            return "move-pane -\(direction == .horizontal ? "v" : "h")\(source.raw.isEmpty ? "" : " -s \(source.raw)")"
        case .renumberWindows: return "renumber-windows"
        case .lastWindow: return "last-window"
        case .sendPrefix: return "send-prefix"
        case let .sourceFile(path): return "source-file \(path)"
        case let .commandPrompt(_, template): return "command-prompt \(template)"
        case let .confirmBefore(_, command): return "confirm-before '\(command.shortDescription)'"
        case let .choose(scope): return "choose-\(scope.rawValue)"
        case let .pipePane(cmd): return cmd.map { "pipe-pane '\($0)'" } ?? "pipe-pane"
        case .lockClient: return "lock-client"
        case .clockMode: return "clock-mode"
        case let .switchClientTable(table): return "switch-client -T \(table)"
        case let .linkWindow(target): return "link-window -t \(target)"
        case .unlinkWindow: return "unlink-window"
        case let .displayPopup(command): return command.map { "display-popup -E '\($0)'" } ?? "display-popup"
        case let .displayMenu(items): return "display-menu (\(items.count) items)"
        case let .targeted(spec, command):
            return "\(command.shortDescription)\(spec.raw.isEmpty ? "" : " -t \(spec.raw)")"
        }
    }
}
