import Foundation

public enum TerminalColorRenderingMode: String, Codable, Sendable {
    case accurate
    case vivid
}

public enum TerminalColorGamut: String, Codable, Sendable {
    case sRGB = "srgb"
    case displayP3 = "display-p3"
    case auto

    public static func resolved(
        renderingMode: TerminalColorRenderingMode,
        requested: TerminalColorGamut
    ) -> TerminalColorGamut {
        switch renderingMode {
        case .accurate:
            // Accurate mode is the authored sRGB identity path regardless of the stored gamut.
            return .sRGB
        case .vivid:
            // This task's wide-gamut path is explicit Display-P3 output.
            return .displayP3
        }
    }
}
