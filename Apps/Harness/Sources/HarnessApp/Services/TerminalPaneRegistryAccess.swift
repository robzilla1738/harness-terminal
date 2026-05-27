import Foundation
import HarnessCore
import HarnessTerminalKit

@MainActor
enum TerminalPaneRegistryAccess {
    static func host(for surfaceID: SurfaceID) -> TerminalHostView? {
        SessionCoordinator.shared.terminalHostIfExists(for: surfaceID)
    }
}
