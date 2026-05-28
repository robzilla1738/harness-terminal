/// Value for Ghostty's `window-colorspace` config key.
///
/// `srgb` matches Ghostty.app defaults for hex/ANSI interpretation. Harness does
/// not pin NSWindow or CALayer color spaces; libghostty owns terminal compositing.
public enum TerminalColorspace: Sendable {
    case srgb
    case displayP3

    public static let active: TerminalColorspace = .srgb

    public var ghosttyConfigValue: String {
        switch self {
        case .srgb: return "srgb"
        case .displayP3: return "display-p3"
        }
    }
}
