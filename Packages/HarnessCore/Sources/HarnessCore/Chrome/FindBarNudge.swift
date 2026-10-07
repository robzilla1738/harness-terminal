import Foundation

/// Where the find bar sits. Coordinates are top-left origin, y down.
/// The bar is an overlay: `changesRowCount` is false and row count is not an input.
public enum FindBarNudge {
    public static let changesRowCount = false

    public struct Box: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }

        public func intersects(_ other: Box) -> Bool {
            x < other.maxX && maxX > other.x && y < other.maxY && maxY > other.y
        }
    }

    /// Preferred corner is top-trailing. If that covers `match`, move below it,
    /// then to the leading edge, then above it.
    public static func place(
        viewportWidth: Double,
        viewportHeight: Double,
        barWidth: Double,
        barHeight: Double,
        match: Box?,
        preferredTop: Double = 8,
        preferredTrailing: Double = 10,
        gap: Double = 6
    ) -> Box {
        let preferred = Box(
            x: viewportWidth - preferredTrailing - barWidth,
            y: preferredTop,
            width: barWidth,
            height: barHeight
        )
        guard let match, preferred.intersects(match) else { return preferred }
        let below = Box(x: preferred.x, y: match.maxY + gap, width: barWidth, height: barHeight)
        if below.maxY <= viewportHeight { return below }
        let leading = Box(x: preferredTrailing, y: preferredTop, width: barWidth, height: barHeight)
        if !leading.intersects(match) { return leading }
        return Box(x: preferred.x, y: max(0, match.y - gap - barHeight), width: barWidth, height: barHeight)
    }
}
