import AppKit

/// Where two dividers meet at a right angle (a split inside one side of a perpendicular
/// split), dragging the junction moves both at once, like resizing a window by its corner.
@MainActor
final class SplitCornerHandle: NSView {
    static let side: CGFloat = 14

    /// `across` has the divider the other one ends on; `along` is the nested split.
    weak var across: HarnessSplitView?
    weak var along: HarnessSplitView?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .frameResize(position: .topLeft, directions: .all))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let across, let along else { return }
        for split in [across, along] {
            let point = split.convert(event.locationInWindow, from: nil)
            // NSSplitView is flipped, so a horizontal divider's position counts from the top.
            split.setPosition(split.isVertical ? point.x : point.y, ofDividerAt: 0)
        }
        superview?.needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        across?.saveRatio()
        along?.saveRatio()
    }

    /// Junctions of `splits` (all in `space`), as handle frames in `space`.
    static func junctions(of splits: [HarnessSplitView], in space: NSView) -> [(across: HarnessSplitView, along: HarnessSplitView, frame: NSRect)] {
        var found: [(HarnessSplitView, HarnessSplitView, NSRect)] = []
        for across in splits {
            guard let line = dividerLine(across, in: space) else { continue }
            for along in splits where along !== across && along.isVertical != across.isVertical && along.isDescendant(of: across) {
                guard let inner = dividerLine(along, in: space) else { continue }
                // The nested divider must end on the outer one.
                let tolerance: CGFloat = 16
                let point: NSPoint
                if across.isVertical {
                    guard abs(inner.minX - line.midX) < tolerance || abs(inner.maxX - line.midX) < tolerance,
                          inner.midY > line.minY, inner.midY < line.maxY else { continue }
                    point = NSPoint(x: line.midX, y: inner.midY)
                } else {
                    guard abs(inner.minY - line.midY) < tolerance || abs(inner.maxY - line.midY) < tolerance,
                          inner.midX > line.minX, inner.midX < line.maxX else { continue }
                    point = NSPoint(x: inner.midX, y: line.midY)
                }
                found.append((across, along, NSRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)))
            }
        }
        return found
    }

    /// The divider of `split` as a thin rect along its length, in `space`.
    private static func dividerLine(_ split: HarnessSplitView, in space: NSView) -> NSRect? {
        guard split.subviews.count == 2 else { return nil }
        let first = split.subviews[0].frame
        let rect = split.isVertical
            ? NSRect(x: first.maxX, y: 0, width: split.dividerThickness, height: split.bounds.height)
            : NSRect(x: 0, y: first.maxY, width: split.bounds.width, height: split.dividerThickness)
        return space.convert(rect, from: split)
    }
}
