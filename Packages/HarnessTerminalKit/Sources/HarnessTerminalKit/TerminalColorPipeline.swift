import GhosttyTerminal

/// Ghostty config keys that keep embedded terminal TUI colors matching Ghostty.app.
///
/// Uses macOS Ghostty defaults for color interpretation/blending. Color
/// translucency uses libghostty `background-opacity`; blur is applied once at the
/// window level via `WindowBlur` (CGS) so the terminal and chrome share a single
/// uniform blur (libghostty's own `background-blur` is a no-op in embedded mode).
enum TerminalColorPipeline {
    /// macOS Ghostty default — Display P3 native blending with sRGB color interpretation.
    static let alphaBlendingValue = "native"

    static func apply(to builder: inout TerminalConfiguration.Builder) {
        builder.withCustom("background-opacity-cells", "false")
        builder.withCustom("window-colorspace", TerminalColorspace.active.ghosttyConfigValue)
        builder.withCustom("alpha-blending", alphaBlendingValue)
    }

    static let requiredRenderedConfigLines = [
        "background-opacity-cells = false",
        "window-colorspace = \(TerminalColorspace.active.ghosttyConfigValue)",
        "alpha-blending = \(alphaBlendingValue)",
    ]
}
