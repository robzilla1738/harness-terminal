import Foundation

/// The one writer for `HarnessSettings`. The settings window and the command
/// palette both call this, so a control cannot land in two shapes.
public enum SettingsEditor {
    public static func applyFromWindow<T>(
        _ keyPath: WritableKeyPath<HarnessSettings, T>,
        _ value: T,
        on settings: inout HarnessSettings
    ) {
        settings[keyPath: keyPath] = value
    }

    public static func applyFromPalette<T>(
        _ keyPath: WritableKeyPath<HarnessSettings, T>,
        _ value: T,
        on settings: inout HarnessSettings
    ) {
        settings[keyPath: keyPath] = value
    }

    public static func setEvent(
        _ event: NotificationEvent,
        _ enabled: Bool,
        on settings: inout HarnessSettings
    ) {
        settings.setEventEnabled(event, enabled)
    }
}

/// Daemon `set-option` values. The Advanced page and the palette build the same command.
public enum DaemonSettingsControls {
    public static func command(key: String, rawValue: String) -> Command {
        .setOption(scope: "global", target: nil, key: key, rawValue: rawValue)
    }

    /// The daemon request for `command`. Global scope keeps a nil target.
    public static func request(key: String, rawValue: String) -> IPCRequest {
        switch command(key: key, rawValue: rawValue) {
        case let .setOption(scope, target, optionKey, optionValue):
            return .setOption(scope: scope, target: target, key: optionKey, rawValue: optionValue)
        default:
            return .setOption(scope: "global", target: nil, key: key, rawValue: rawValue)
        }
    }

    /// Keys the Advanced page edits. `values` nil means a free string.
    public static let rows: [(id: String, title: String, key: String, values: [String]?)] = [
        ("status-position", "Status position", "status-position", ["bottom", "top"]),
        ("status-left", "Status left", "status-left", nil),
        ("status-right", "Status right", "status-right", nil),
        ("mouse", "Mouse reporting", "mouse", ["off", "on"]),
        ("mode-keys", "Copy-mode keys", "mode-keys", ["vi", "emacs"]),
        ("set-clipboard", "OSC 52 clipboard", "set-clipboard", ["off", "on"]),
        ("terminal-identity", "Reported identity", "terminal-identity", ["compatible", "harness"]),
        ("base-index", "Window base index", "base-index", ["0", "1"]),
        ("pane-base-index", "Pane base index", "pane-base-index", ["0", "1"]),
        ("renumber-windows", "Renumber windows", "renumber-windows", ["off", "on"]),
        ("allow-rename", "Program tab titles", "allow-rename", ["off", "on"]),
        ("automatic-rename", "Automatic rename", "automatic-rename", ["off", "on"]),
        ("monitor-activity", "Monitor activity", "monitor-activity", ["off", "on"]),
        ("monitor-bell", "Monitor bell", "monitor-bell", ["off", "on"]),
        ("monitor-silence", "Silence alert", "monitor-silence", nil),
        ("remain-on-exit", "Remain on exit", "remain-on-exit", ["off", "on"]),
        ("repeat-time", "Prefix repeat", "repeat-time", nil),
        ("history-limit", "History limit", "history-limit", nil),
        ("pane-border-status", "Pane border labels", "pane-border-status", ["off", "top", "bottom"]),
        ("pane-border-format", "Border format", "pane-border-format", nil),
        ("word-separators", "Word separators", "word-separators", nil),
    ]
}
