import GhosttyTerminal

/// Ghostty config keys that keep embedded terminal TUI colors crisp and accurate.
///
/// Color interpretation defaults to sRGB (`TerminalColorspace.active`), matching
/// Ghostty.app. Rich color depends on the host view being layer-HOSTING (see
/// `AppTerminalView.commonInit`) so AppKit doesn't clamp the renderer's wide-gamut
/// output. The "Vivid colors" setting switches to `display-p3` for extra
/// saturation. Color translucency uses libghostty `background-opacity`; blur is
/// applied once at the window level via `WindowBlur` (CGS) so the terminal and
/// chrome share a single uniform blur (libghostty's own `background-blur` is a
/// no-op in embedded mode).
enum TerminalColorPipeline {
    /// macOS-native (gamma-incorrect) alpha blending — Ghostty's macOS default.
    static let nativeAlphaBlending = "native"
    /// Gamma-correct alpha blending — crisper text antialiasing on some setups.
    static let linearAlphaBlending = "linear-corrected"

    static func apply(
        to builder: inout TerminalConfiguration.Builder,
        colorspace: TerminalColorspace = TerminalColorspace.active,
        alphaBlending: String = nativeAlphaBlending
    ) {
        builder.withCustom("background-opacity-cells", "false")
        builder.withCustom("window-colorspace", colorspace.ghosttyConfigValue)
        builder.withCustom("alpha-blending", alphaBlending)
    }

    static let requiredRenderedConfigLines = [
        "background-opacity-cells = false",
        "window-colorspace = \(TerminalColorspace.active.ghosttyConfigValue)",
        "alpha-blending = \(nativeAlphaBlending)",
    ]
}
