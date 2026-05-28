import GhosttyTerminal

/// Ghostty config keys that keep embedded terminal TUI colors matching Ghostty.app.
///
/// Uses macOS Ghostty defaults for color interpretation/blending. Translucency +
/// blur use libghostty `background-opacity` / `background-blur` only — do not
/// apply `WindowBlur` (CGS) over the terminal output.
enum TerminalColorPipeline {
    /// macOS Ghostty default — Display P3 native blending with sRGB color interpretation.
    static let alphaBlendingValue = "native"

    static func apply(to builder: inout TerminalConfiguration.Builder) {
        builder.withCustom("background-opacity-cells", "true")
        builder.withCustom("window-colorspace", TerminalColorspace.active.ghosttyConfigValue)
        builder.withCustom("alpha-blending", alphaBlendingValue)
    }

    static let requiredRenderedConfigLines = [
        "background-opacity-cells = true",
        "window-colorspace = \(TerminalColorspace.active.ghosttyConfigValue)",
        "alpha-blending = \(alphaBlendingValue)",
    ]
}
