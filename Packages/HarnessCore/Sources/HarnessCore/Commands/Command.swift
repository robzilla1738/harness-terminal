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

    // MARK: Tab / window operations
    case newWindow                                 // new-window
    case killWindow                                // kill-window
    case renameWindow(newName: String?)            // rename-window [-N name]
    case nextWindow
    case previousWindow
    case selectWindow(index: Int)                  // select-window -t :<n>

    // MARK: Session / workspace operations
    case newSession(name: String?)
    case killSession
    case renameSession(newName: String?)
    case selectWorkspace(index: Int)               // workspace 0..9
    case nextWorkspace
    case previousWorkspace

    // MARK: Modes
    case copyMode                                  // toggle copy mode
    case detachClient                              // detach the calling client

    // MARK: Scripting
    case sendKeys(keys: [String])
    case displayMessage(format: String)
    case runShell(shellCommand: String)

    // MARK: Bindings + config
    case bindKey(table: String, spec: String, command: Command)
    case unbindKey(table: String, spec: String)
    case listKeys(table: String?)
    case sourceConfig                              // re-import Ghostty config
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

    public enum PaneTarget: String, Codable, Sendable, Equatable {
        case left, right, up, down
        case next, previous, last
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
        case .newWindow: return "new-window"
        case .killWindow: return "kill-window"
        case let .renameWindow(name): return "rename-window\(name.map { " \($0)" } ?? "")"
        case .nextWindow: return "next-window"
        case .previousWindow: return "previous-window"
        case let .selectWindow(index): return "select-window -t :\(index)"
        case let .newSession(name): return "new-session\(name.map { " -s \($0)" } ?? "")"
        case .killSession: return "kill-session"
        case let .renameSession(name): return "rename-session\(name.map { " \($0)" } ?? "")"
        case let .selectWorkspace(index): return "select-workspace \(index)"
        case .nextWorkspace: return "next-workspace"
        case .previousWorkspace: return "previous-workspace"
        case .copyMode: return "copy-mode"
        case .detachClient: return "detach-client"
        case let .sendKeys(keys): return "send-keys \(keys.joined(separator: " "))"
        case let .displayMessage(format): return "display-message \(format)"
        case let .runShell(cmd): return "run-shell '\(cmd)'"
        case let .bindKey(table, spec, command): return "bind-key -T \(table) \(spec) \(command.shortDescription)"
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
        }
    }
}
