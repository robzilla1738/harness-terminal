import AppKit
import HarnessCore
import HarnessTerminalKit

/// A tab drawn as its panes, split the way its window splits them (Overview tiles, tab peek).
/// A pane that has a terminal in this app, shown or not, is drawn live from it; any other shows
/// the daemon's latest capture, which the owner fetches with `capture(_:then:)`. Never creates
/// a terminal view or resizes a PTY.
@MainActor
final class TabThumbnailView: NSView {
    private let root: PaneNode
    private var panes: [SurfaceID: TerminalThumbnailView] = [:]
    /// The panes with no terminal in this app: they show captures.
    private(set) var capturedSurfaces: [SurfaceID] = []

    init(root: PaneNode) {
        self.root = root
        super.init(frame: .zero)
        let coordinator = SessionCoordinator.shared
        for surface in root.allSurfaceIDs() {
            let pane = TerminalThumbnailView()
            pane.layer?.cornerRadius = HarnessDesign.Radius.control
            pane.layer?.cornerCurve = .continuous
            pane.layer?.masksToBounds = true
            if let host = coordinator.terminalHostIfExists(for: surface) {
                pane.follow(host)
            } else {
                capturedSurfaces.append(surface)
            }
            panes[surface] = pane
            addSubview(pane)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ captures: [SurfaceID: TerminalThumbnail]) {
        for surface in capturedSurfaces {
            if let capture = captures[surface] { panes[surface]?.show(capture) }
        }
    }

    override func layout() {
        super.layout()
        place(root, in: bounds)
    }

    /// `.horizontal` puts the panes side by side (first on the left), `.vertical` stacks them.
    private func place(_ node: PaneNode, in rect: NSRect) {
        switch node {
        case let .leaf(leaf):
            panes[leaf.surfaceID]?.frame = rect
        case let .branch(direction, ratio, first, second):
            let gap = HarnessDesign.Spacing.xxs
            let edge: CGRectEdge = direction == .horizontal ? .minXEdge : .minYEdge
            let length = direction == .horizontal ? rect.width : rect.height
            let (head, rest) = rect.divided(atDistance: ((length - gap) * CGFloat(ratio)).rounded(), from: edge)
            place(first, in: head)
            place(second, in: rest.divided(atDistance: gap, from: edge).remainder)
        }
    }

    /// Captures of `surfaces` on the active daemon (the one whose tabs the Overview and the peek
    /// show), fetched off the main thread. They draw in the active pane's style: a pane without
    /// a terminal has no style of its own, and the active pane's carries the current theme.
    static func capture(_ surfaces: [SurfaceID], then done: @escaping @MainActor @Sendable ([SurfaceID: TerminalThumbnail]) -> Void) {
        let coordinator = SessionCoordinator.shared
        guard !surfaces.isEmpty,
              let style = coordinator.activeSurfaceID.flatMap(coordinator.terminalHostIfExists)?.thumbnailStyle
        else { return done([:]) }
        let endpoint = coordinator.activeEndpoint
        DispatchQueue.global(qos: .userInitiated).async {
            let client = DaemonClient(endpoint: endpoint)
            var captures: [SurfaceID: TerminalThumbnail] = [:]
            for surface in surfaces {
                // The screen alone, untrimmed: `rows` lines. An older daemon sends its history
                // too, and the thumbnail keeps the last `rows` lines either way.
                guard case let .text(json)? = try? client.request(.paneQuery(surfaceID: surface.uuidString, kind: "size"), timeout: 1),
                      let size = try? JSONDecoder().decode(PaneSize.self, from: Data(json.utf8)),
                      size.cols > 0, size.rows > 0,
                      case let .text(vt)? = try? client.request(
                          .captureFormatted(surfaceID: surface.uuidString, format: "vt", trim: false, unwrap: false, screen: true), timeout: 1
                      )
                else { continue }
                captures[surface] = TerminalThumbnail(capture: vt, columns: size.cols, rows: size.rows, style: style)
            }
            let result = captures
            DispatchQueue.main.async {
                MainActor.assumeIsolated { done(result) }
            }
        }
    }

    /// The daemon's `pane.size` answer.
    private struct PaneSize: Decodable {
        var cols: Int
        var rows: Int
    }
}
