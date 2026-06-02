import Foundation

public struct NotchScreenMetrics: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var width: Double
    public var height: Double
    public var safeAreaTop: Double
    public var auxiliaryTopLeftMaxX: Double?
    public var auxiliaryTopRightMinX: Double?

    public init(
        minX: Double,
        minY: Double,
        width: Double,
        height: Double,
        safeAreaTop: Double = 0,
        auxiliaryTopLeftMaxX: Double? = nil,
        auxiliaryTopRightMinX: Double? = nil
    ) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftMaxX = auxiliaryTopLeftMaxX
        self.auxiliaryTopRightMinX = auxiliaryTopRightMinX
    }
}

public struct NotchRect: Sendable, Equatable {
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
}

public struct NotchLayoutMetrics: Sendable, Equatable {
    public static let fallbackClosedWidth: Double = 176
    public static let fallbackClosedHeight: Double = 28
    public static let minimumOpenWidth: Double = 336
    public static let preferredOpenWidth: Double = 540
    public static let preferredOpenHeight: Double = 286
    public static let shadowPadding: Double = 20

    public var hasPhysicalNotch: Bool
    public var closedWidth: Double
    public var closedHeight: Double
    public var openWidth: Double
    public var openHeight: Double
    public var panelFrame: NotchRect

    public init(
        hasPhysicalNotch: Bool,
        closedWidth: Double,
        closedHeight: Double,
        openWidth: Double,
        openHeight: Double,
        panelFrame: NotchRect
    ) {
        self.hasPhysicalNotch = hasPhysicalNotch
        self.closedWidth = closedWidth
        self.closedHeight = closedHeight
        self.openWidth = openWidth
        self.openHeight = openHeight
        self.panelFrame = panelFrame
    }

    public static func compute(for screen: NotchScreenMetrics) -> NotchLayoutMetrics {
        let availableWidth = max(160, screen.width)
        let hasNotch = screen.safeAreaTop > 0
        let inferredNotchWidth = notchWidth(from: screen)
        let closedWidth = clamp(
            inferredNotchWidth ?? fallbackClosedWidth,
            min: 152,
            max: min(250, availableWidth - 24)
        )
        let closedHeight: Double
        if hasNotch {
            closedHeight = clamp(screen.safeAreaTop, min: 30, max: 40)
        } else {
            closedHeight = fallbackClosedHeight
        }
        let maxOpenWidth = max(280, availableWidth - 32)
        let minOpenWidth = min(minimumOpenWidth, maxOpenWidth)
        let openWidth = clamp(preferredOpenWidth, min: minOpenWidth, max: maxOpenWidth)
        let openHeight = preferredOpenHeight
        let panelWidth = openWidth + shadowPadding * 2
        let panelHeight = openHeight + shadowPadding
        let panelX = (screen.minX + screen.width / 2 - panelWidth / 2).rounded()
        let panelY = (screen.minY + screen.height - panelHeight).rounded()

        return NotchLayoutMetrics(
            hasPhysicalNotch: hasNotch,
            closedWidth: closedWidth.rounded(),
            closedHeight: closedHeight.rounded(),
            openWidth: openWidth.rounded(),
            openHeight: openHeight.rounded(),
            panelFrame: NotchRect(
                x: panelX,
                y: panelY,
                width: panelWidth.rounded(),
                height: panelHeight.rounded()
            )
        )
    }

    private static func notchWidth(from screen: NotchScreenMetrics) -> Double? {
        guard let leftMaxX = screen.auxiliaryTopLeftMaxX,
              let rightMinX = screen.auxiliaryTopRightMinX
        else { return nil }
        let width = rightMinX - leftMaxX
        guard width >= 120 else { return nil }
        return width
    }

    private static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.max(minimum, Swift.min(maximum, value))
    }
}
