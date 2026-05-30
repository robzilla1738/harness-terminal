import Foundation

/// A parsed tmux pane style (`window-style`/`window-active-style`/`pane-style`/
/// `pane-active-style`) — the base foreground/background a pane's default-colored cells
/// inherit. `nil` for a channel = no override (the surface keeps its theme default);
/// `.some(.none)` = the style explicitly said `default` (so it overrides a more general
/// style back to the surface default — see `PaneStyleSet.base`).
///
/// Renderer-agnostic: the ssh compositor maps these colors to SGR palette/truecolor codes,
/// the GUI maps them to `RGBColor` via `FormatColor.rgbComponents()`. One parser, two
/// surfaces — no per-front-end style logic.
public struct PaneStyle: Equatable, Sendable {
    public var fg: FormatColor?
    public var bg: FormatColor?

    public init(fg: FormatColor? = nil, bg: FormatColor? = nil) {
        self.fg = fg
        self.bg = bg
    }

    public var isEmpty: Bool { fg == nil && bg == nil }

    /// Parse a comma-separated style string (`fg=colour245,bg=#262626`). Only `fg=`/`bg=`
    /// are meaningful for a pane base style; other attrs (bold, etc.) are ignored. An empty
    /// string yields an empty style.
    public static func parse(_ string: String) -> PaneStyle {
        var style = PaneStyle()
        for raw in string.split(separator: ",") {
            let p = raw.trimmingCharacters(in: .whitespaces)
            if p.lowercased().hasPrefix("fg=") { style.fg = FormatColor.parse(String(p.dropFirst(3))) }
            else if p.lowercased().hasPrefix("bg=") { style.bg = FormatColor.parse(String(p.dropFirst(3))) }
        }
        return style
    }
}

/// The four pane-style options resolved together. `base(active:)` yields the effective
/// base style for a pane given whether it is the active pane, applying tmux precedence:
/// the active pane prefers `pane-active-style` → `window-active-style`, then falls through
/// to the general `pane-style` → `window-style` (so setting only `window-style` dims *all*
/// panes, matching tmux); an inactive pane uses `pane-style` → `window-style`.
public struct PaneStyleSet: Equatable, Sendable {
    public var window: PaneStyle
    public var windowActive: PaneStyle
    public var pane: PaneStyle
    public var paneActive: PaneStyle

    public init(
        window: PaneStyle = PaneStyle(),
        windowActive: PaneStyle = PaneStyle(),
        pane: PaneStyle = PaneStyle(),
        paneActive: PaneStyle = PaneStyle()
    ) {
        self.window = window
        self.windowActive = windowActive
        self.pane = pane
        self.paneActive = paneActive
    }

    /// Build from raw option strings (any may be empty/unset).
    public init(window: String, windowActive: String, pane: String, paneActive: String) {
        self.init(
            window: PaneStyle.parse(window),
            windowActive: PaneStyle.parse(windowActive),
            pane: PaneStyle.parse(pane),
            paneActive: PaneStyle.parse(paneActive)
        )
    }

    public var isEmpty: Bool {
        window.isEmpty && windowActive.isEmpty && pane.isEmpty && paneActive.isEmpty
    }

    /// The effective base style for a pane. A channel resolves to nil ("no override") when
    /// the winning style is unset *or* explicitly `default` (`.some(.none)`) — so an
    /// `*-active-style fg=default` cancels a dim inherited from `window-style` on the active
    /// pane, while leaving inactive panes dimmed.
    public func base(active: Bool) -> PaneStyle {
        func channel(_ kp: KeyPath<PaneStyle, FormatColor?>) -> FormatColor? {
            let winning: FormatColor?
            if active {
                winning = paneActive[keyPath: kp] ?? windowActive[keyPath: kp]
                    ?? pane[keyPath: kp] ?? window[keyPath: kp]
            } else {
                winning = pane[keyPath: kp] ?? window[keyPath: kp]
            }
            // `.some(.none)` = explicit `default` → no override for application.
            if case .some(.none) = winning { return nil }
            return winning
        }
        return PaneStyle(fg: channel(\.fg), bg: channel(\.bg))
    }
}
