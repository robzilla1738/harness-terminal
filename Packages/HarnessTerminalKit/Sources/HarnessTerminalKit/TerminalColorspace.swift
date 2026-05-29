/// Value for Ghostty's `window-colorspace` config key.
///
/// `srgb` matches Ghostty.app's default and renders rich, accurate color — once
/// the host view is layer-HOSTING (see `AppTerminalView.commonInit`) so AppKit
/// doesn't clamp the renderer's wide-gamut output. `display-p3` skips the shader's
/// sRGB→P3 conversion for extra saturation; exposed via the "Vivid colors" toggle.
public enum TerminalColorspace: Sendable {
    case srgb
    case displayP3

    /// Ghostty.app parity default.
    public static let active: TerminalColorspace = .srgb

    public var ghosttyConfigValue: String {
        switch self {
        case .srgb: return "srgb"
        case .displayP3: return "display-p3"
        }
    }
}
