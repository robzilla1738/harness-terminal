import AppKit
import HarnessTerminalRenderer
import Metal
import QuartzCore

/// A pane a thumbnail can follow live.
@MainActor
public protocol TerminalThumbnailSource: AnyObject {
    /// Bumps each time output reaches the pane's screen.
    var outputGeneration: UInt64 { get }
    /// The pane's screen, built off the main thread and handed back on it.
    func thumbnail(_ done: @escaping @MainActor @Sendable (TerminalThumbnail) -> Void)
}

extension HarnessTerminalSurfaceView: TerminalThumbnailSource {}
extension TerminalHostView: TerminalThumbnailSource {}

/// A pane drawn small by its own renderer: the pane's font rasterized at the thumbnail's scale,
/// its colors, cursor, ligatures, box drawing, and images, at the pane's real grid size (a
/// thumbnail never resizes anything). Following a pane it redraws at most 15 times a second
/// (once a second with Reduce Motion), only after new output, and only while it's in a window.
@MainActor
public final class TerminalThumbnailView: NSView {
    private static let liveInterval: TimeInterval = 1.0 / 15
    private static let reducedMotionInterval: TimeInterval = 1

    private let metalLayer = CAMetalLayer()
    private var renderer: TerminalMetalRenderer?
    /// What `renderer` was built for: the font and the pixels per point it rasterizes at.
    private var rendererFont: TerminalThumbnailStyle.Font?
    private var rendererScale: CGFloat = 0
    /// Cell size in points for `rendererFont`, measured once per font.
    private var cellMetrics: (font: TerminalThumbnailStyle.Font, metrics: CellMetrics)?
    private var shown: TerminalThumbnail?
    private weak var source: TerminalThumbnailSource?
    private var drawnGeneration: UInt64?
    private var building = false
    private var timer: Timer?
    /// Frames built from the source, for tests.
    private(set) var testingBuildCount = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = metalLayer
        wantsLayer = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = TerminalMetalRenderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.contentsGravity = .topLeft
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    /// Draw `source`'s screen and keep drawing it as its output changes.
    public func follow(_ source: TerminalThumbnailSource) {
        self.source = source
        drawnGeneration = nil
        updateTimer()
    }

    /// Draw this screen: a capture, for a pane with no terminal to follow.
    public func show(_ thumbnail: TerminalThumbnail) {
        shown = thumbnail
        present()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
        present()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        present()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        present()
        // The first frame shouldn't wait a tick (a whole second with Reduce Motion).
        if shown == nil { tick() }
    }

    /// Runs only while there's a pane to follow and a window to draw in.
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard source != nil, window != nil else { return }
        let interval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? Self.reducedMotionInterval : Self.liveInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Build a frame when the source has output this thumbnail hasn't drawn, one at a time,
    /// and only while this thumbnail is on screen in its window (not scrolled out of view).
    func tick() {
        guard let source, !building, source.outputGeneration != drawnGeneration,
              window != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty
        else { return }
        building = true
        testingBuildCount += 1
        let generation = source.outputGeneration
        source.thumbnail { [weak self] thumbnail in
            guard let self else { return }
            building = false
            drawnGeneration = generation
            show(thumbnail)
        }
    }

    private func present() {
        guard let shown, let window, let device = metalLayer.device else { return }
        let backing = window.backingScaleFactor
        let width = Int(bounds.width * backing)
        let height = Int(bounds.height * backing)
        guard width > 0, height > 0 else { return }
        let style = shown.style
        if cellMetrics?.font != style.font {
            let rasterizer = GlyphRasterizer(fontFamily: style.font.family, size: style.font.size)
            cellMetrics = (style.font, rasterizer.metrics())
        }
        guard let metrics = cellMetrics?.metrics else { return }
        let scale = Self.scale(
            fitting: (width, height), columns: shown.frame.columns, rows: shown.frame.rows,
            cell: metrics, backing: backing
        )
        if renderer == nil || rendererFont != style.font || rendererScale != scale {
            // Small glyphs: a quarter-size atlas page holds a thumbnail's working set.
            renderer = TerminalMetalRenderer(
                device: device, fontFamily: style.font.family, fontSize: style.font.size,
                scale: scale, atlasSize: 512,
                fontThicken: style.font.thicken, fontThickenStrength: style.font.thickenStrength
            )
            rendererFont = style.font
            rendererScale = scale
        }
        guard let renderer else { return }
        metalLayer.contentsScale = backing
        metalLayer.drawableSize = CGSize(width: width, height: height)
        metalLayer.isOpaque = style.canvasOpacity >= 1
        metalLayer.colorspace = CGColorSpace(name: style.colorSpaceName as CFString)
        guard let drawable = metalLayer.nextDrawable() else { return }
        let grid = renderer.surfacePixelSize(columns: shown.frame.columns, rows: shown.frame.rows)
        renderer.present(
            shown.frame, to: drawable, clearColor: shown.clearColor,
            origin: (max(0, (width - grid.width) / 2), max(0, (height - grid.height) / 2)),
            gamma: style.gamma, ligatures: style.ligatures
        )
    }

    /// Pixels per point that fit `columns` × `rows` cells of `cell` (points) into `pixels`, never
    /// larger than the pane draws them (`backing`). Cells land on whole device pixels the same
    /// way the renderer rounds them, so the grid always fits and a tile keeps one renderer.
    static func scale(
        fitting pixels: (width: Int, height: Int), columns: Int, rows: Int,
        cell: CellMetrics, backing: CGFloat
    ) -> CGFloat {
        let columns = CGFloat(max(1, columns))
        let rows = CGFloat(max(1, rows))
        var cellHeight = min(
            cell.height * backing,
            CGFloat(pixels.height) / rows,
            CGFloat(pixels.width) / columns * cell.height / cell.width
        ).rounded(.down)
        while cellHeight > 1, columns * (cell.width * cellHeight / cell.height).rounded() > CGFloat(pixels.width) {
            cellHeight -= 1
        }
        return max(1, cellHeight) / cell.height
    }
}
