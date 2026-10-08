import AppKit
import HarnessCore

/// Dragging a pane by its header: onto another pane's edge to split it there, onto its middle
/// to swap the two, onto a tab to move it into that tab, or onto empty tab-bar space to give
/// it a tab of its own. The pasteboard carries only Harness's own type, so a terminal never
/// takes the drop as pasted text.
enum PaneDrag {
    static let type = NSPasteboard.PasteboardType("com.robert.harness.pane")

    static func item(for surfaceID: SurfaceID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(surfaceID.uuidString, forType: type)
        return item
    }

    static func surfaceID(in info: NSDraggingInfo) -> SurfaceID? {
        info.draggingPasteboard.string(forType: type).flatMap(UUID.init(uuidString:))
    }
}

/// The highlight showing where a dragged pane would land. Draws over the pane, takes no clicks.
@MainActor
final class PaneDropHighlightView: NSView {
    var zone: PaneDropZone? {
        didSet { if zone != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let zone else { return }
        let accent = HarnessChrome.current.accent
        let rect = zone.highlight(in: bounds).insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        accent.withAlphaComponent(0.18).setFill()
        path.fill()
        accent.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 2
        path.stroke()
    }
}
