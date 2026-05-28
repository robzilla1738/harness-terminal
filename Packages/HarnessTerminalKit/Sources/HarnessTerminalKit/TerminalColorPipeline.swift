import GhosttyTerminal

/// Ghostty config keys that keep embedded terminal TUI colors matching Ghostty.app.
///
/// Translucency and blur are applied by libghostty. Do not add a second AppKit
/// blur or background layer over terminal output.
enum TerminalColorPipeline {
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
