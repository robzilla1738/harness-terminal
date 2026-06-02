import AppKit
import HarnessCore

@MainActor
enum NotchGeometry {
    static func metrics(for screen: NSScreen) -> NotchLayoutMetrics {
        let frame = screen.frame
        let leftArea = screen.auxiliaryTopLeftArea
        let rightArea = screen.auxiliaryTopRightArea
        let leftMaxX = leftArea.flatMap { $0.isEmpty ? nil : Double($0.maxX) }
        let rightMinX = rightArea.flatMap { $0.isEmpty ? nil : Double($0.minX) }
        return NotchLayoutMetrics.compute(for: NotchScreenMetrics(
            minX: Double(frame.minX),
            minY: Double(frame.minY),
            width: Double(frame.width),
            height: Double(frame.height),
            safeAreaTop: Double(screen.safeAreaInsets.top),
            auxiliaryTopLeftMaxX: leftMaxX,
            auxiliaryTopRightMinX: rightMinX
        ))
    }

    static var fallback: NotchLayoutMetrics {
        NotchLayoutMetrics.compute(for: NotchScreenMetrics(
            minX: 0,
            minY: 0,
            width: 1440,
            height: 900
        ))
    }
}
