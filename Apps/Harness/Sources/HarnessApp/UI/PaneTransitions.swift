import AppKit
import HarnessCore

/// Opening and closing a split, animated. The panes are laid out at their final size at once
/// (so no shell sees a stream of resizes), and only their cards move: a new pane grows out of
/// the one it split from, and a closed pane's card shrinks away into the space its sibling
/// takes. Skipped under Reduce Motion, and for anything but one pane added or removed.
@MainActor
enum PaneTransitions {
    /// Where each pane's card sat before a rebuild, in `space`'s coordinates.
    static func frames(of container: PaneContainerView?, in space: NSView) -> [SurfaceID: NSRect] {
        container?.islandFrames(in: space) ?? [:]
    }

    static func animate(from before: [SurfaceID: NSRect], into container: PaneContainerView, in space: NSView) {
        guard !before.isEmpty, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        space.layoutSubtreeIfNeeded()
        let after = container.islandFrames(in: space)
        let added = Set(after.keys).subtracting(before.keys)
        let removed = Set(before.keys).subtracting(after.keys)
        if added.count == 1, removed.isEmpty, let surface = added.first, let frame = after[surface],
           let island = container.island(for: surface),
           let parent = before.values.first(where: { $0.contains(NSPoint(x: frame.midX, y: frame.midY)) }) {
            grow(island, from: parent, to: frame)
        } else if removed.count == 1, added.isEmpty, let surface = removed.first, let frame = before[surface] {
            let neighbour = after.values.first { $0.intersects(frame.insetBy(dx: -24, dy: -24)) }
            ghost(of: frame, shrinkingToward: neighbour, in: space)
        }
    }

    /// The new card starts small and transparent at the side of `parent` it split from.
    private static func grow(_ island: NSView, from parent: NSRect, to frame: NSRect) {
        guard let layer = island.layer else { return }
        let dx = (parent.midX - frame.midX) * 0.35
        let dy = (parent.midY - frame.midY) * 0.35
        let start = transform(scale: 0.94, offset: CGPoint(x: dx, y: dy), size: frame.size)
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: start)
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = HarnessDesign.Motion.standard
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
        layer.add(group, forKey: "paneOpen")
    }

    /// A card-colored stand-in for the closed pane fades and shrinks toward its neighbour.
    private static func ghost(of frame: NSRect, shrinkingToward neighbour: NSRect?, in space: NSView) {
        let c = HarnessChrome.current
        let ghost = NSView(frame: frame)
        ghost.wantsLayer = true
        ghost.layer?.backgroundColor = c.terminalBackground.withAlphaComponent(HarnessChrome.paintOpacity).cgColor
        ghost.layer?.cornerRadius = HarnessDesign.Radius.overlay
        ghost.layer?.borderWidth = 1
        ghost.layer?.borderColor = c.borderStrong.cgColor
        space.addSubview(ghost, positioned: .above, relativeTo: nil)
        let toward = neighbour.map { CGPoint(x: ($0.midX - frame.midX) * 0.3, y: ($0.midY - frame.midY) * 0.3) } ?? .zero
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = HarnessDesign.Motion.fast
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            ghost.animator().alphaValue = 0
            ghost.animator().frame = frame.insetBy(dx: frame.width * 0.04, dy: frame.height * 0.04).offsetBy(dx: toward.x, dy: toward.y)
        }, completionHandler: { [weak ghost] in
            DispatchQueue.main.async { [weak ghost] in ghost?.removeFromSuperview() }
        })
    }

    /// Scale about the card's center, then shift.
    private static func transform(scale: CGFloat, offset: CGPoint, size: CGSize) -> CATransform3D {
        var t = CATransform3DMakeTranslation(offset.x + size.width / 2, offset.y + size.height / 2, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -size.width / 2, -size.height / 2, 0)
    }
}
