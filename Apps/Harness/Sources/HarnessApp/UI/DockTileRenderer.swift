import AppKit
import HarnessCore

/// The Dock icon as a status board: up to four agents under the app icon, each ringed by its
/// attention (red blocked or failed, green done, accent working), and a badge counting what
/// needs you. Redrawn only when that state changes; with no agents the plain icon shows.
@MainActor
final class DockTileRenderer {
    static let shared = DockTileRenderer()

    struct Mark: Equatable {
        var kind: AgentKind
        var rank: AttentionRank
    }

    private var shown: (marks: [Mark], needsYou: Int)?

    static func markFrames(count: Int, in bounds: NSRect) -> [NSRect] {
        guard count > 0 else { return [] }
        let gap = bounds.width * 0.02
        let side = min(bounds.width * 0.3,
                       (bounds.width * 0.92 - CGFloat(count - 1) * gap) / CGFloat(count))
        let total = CGFloat(count) * side + CGFloat(count - 1) * gap
        return (0..<count).map { index in
            NSRect(x: bounds.midX - total / 2 + CGFloat(index) * (side + gap),
                   y: bounds.minY + bounds.height * 0.02, width: side, height: side)
        }
    }

    func update(from snapshot: SessionSnapshot) {
        let tabs = snapshot.workspaces.flatMap(\.sessions).flatMap(\.tabs)
        let ranked = AttentionRank.sorted(tabs, rank: AttentionRank.of, lastActivity: { $0.agent?.lastActivityAt })
        let marks = ranked.compactMap { tab -> Mark? in
            guard let kind = tab.agent?.kind ?? AgentTitleInference.kind(from: tab.title) else { return nil }
            return Mark(kind: kind, rank: AttentionRank.of(tab))
        }.prefix(4)
        let needsYou = tabs.filter { AttentionRank.of($0).needsYou }.count
        let state = (Array(marks), needsYou)
        if let shown, shown.marks == state.0, shown.needsYou == state.1 { return }
        shown = state

        let tile = NSApp.dockTile
        tile.badgeLabel = needsYou > 0 ? "\(needsYou)" : nil
        if marks.isEmpty {
            tile.contentView = nil
        } else {
            let view = DockTileView(frame: NSRect(origin: .zero, size: tile.size))
            view.marks = Array(marks)
            tile.contentView = view
        }
        tile.display()
    }
}

private final class DockTileView: NSView {
    var marks: [DockTileRenderer.Mark] = []

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        for (mark, disc) in zip(marks, DockTileRenderer.markFrames(count: marks.count, in: bounds)) {
            let side = disc.width
            NSColor(white: 0.08, alpha: 0.92).setFill()
            NSBezierPath(ovalIn: disc).fill()
            let ring = NSBezierPath(ovalIn: disc.insetBy(dx: side * 0.05, dy: side * 0.05))
            ring.lineWidth = side * 0.1
            Self.color(for: mark.rank).setStroke()
            ring.stroke()
            let icon = AgentIconRenderer.templateOrMonogramImage(for: mark.kind, size: side * 0.55)
            Self.tinted(icon, .white).draw(in: disc.insetBy(dx: side * 0.225, dy: side * 0.225))
        }
    }

    private static func color(for rank: AttentionRank) -> NSColor {
        switch rank {
        case .waiting, .blocked, .error: return .systemRed
        case .done: return .systemGreen
        case .working: return HarnessChrome.current.accent
        case .idle: return NSColor(white: 0.5, alpha: 1)
        }
    }

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
