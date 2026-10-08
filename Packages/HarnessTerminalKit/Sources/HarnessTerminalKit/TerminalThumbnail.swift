import CoreGraphics
import Foundation
import HarnessTerminalEngine
import HarnessTerminalRenderer
import HarnessTheme

/// How a pane draws: the colors its frames are built with, and the font and text settings its
/// renderer uses. A thumbnail draws in its pane's style, so it looks like the pane.
public struct TerminalThumbnailStyle: Sendable {
    /// What a thumbnail's renderer is built for; a change rebuilds it.
    struct Font: Equatable, Sendable {
        var family: String
        var size: CGFloat
        var thicken: Bool
        var thickenStrength: Int
    }

    /// Builds frames in the pane's colors; the flag is reverse video (DECSCNM).
    let makeBuilder: @Sendable (Bool) -> FrameBuilder
    let canvasBackground: RGBColor
    let canvasForeground: RGBColor
    let canvasOpacity: Float
    let font: Font
    let gamma: Float
    let ligatures: Bool
    /// The colorspace the pane tags its layer with (sRGB, or Display P3 for vivid color).
    let colorSpaceName: String

    /// The live screen (never a scrolled-back view, a selection, or find highlights) as this
    /// pane draws it while unfocused. Only reads `emulator`: no damage is consumed.
    func thumbnail(of emulator: TerminalEmulator) -> TerminalThumbnail {
        let grid = emulator.readGrid()
        let reverseVideo = emulator.modes.reverseVideo
        let builder = makeBuilder(reverseVideo)
        var frame = builder.build(grid, region: nil, imageProvider: { emulator.image(for: $0) })
        switch grid.cursor.shape {
        case .block: frame.cursor.style = .block
        case .bar: frame.cursor.style = .bar
        case .underline: frame.cursor.style = .underline
        case .default: break
        }
        frame.cursor.hollow = true
        return TerminalThumbnail(
            frame: frame,
            clearColor: builder.renderColor(reverseVideo ? canvasForeground : canvasBackground, alpha: canvasOpacity),
            style: self
        )
    }
}

/// One pane's screen, built and ready for a `TerminalThumbnailView` to draw.
public struct TerminalThumbnail: Sendable {
    let frame: TerminalFrame
    let clearColor: RenderColor
    let style: TerminalThumbnailStyle

    /// A pane no window has mounted, from the daemon's `vt` capture (untrimmed): its last `rows`
    /// lines laid out in a scratch emulator, drawn in `style`. The scratch emulator answers
    /// nothing and the capture doesn't say where the cursor is, so none is drawn.
    public init(capture vt: String, columns: Int, rows: Int, style: TerminalThumbnailStyle) {
        let emulator = TerminalEmulator(cols: columns, rows: rows)
        emulator.readsGraphicsFiles = false
        let screen = vt.split(separator: "\n", omittingEmptySubsequences: false).suffix(rows)
        emulator.feed(Data(("\u{1b}[?25l" + screen.joined(separator: "\r\n")).utf8))
        self = style.thumbnail(of: emulator)
    }

    init(frame: TerminalFrame, clearColor: RenderColor, style: TerminalThumbnailStyle) {
        self.frame = frame
        self.clearColor = clearColor
        self.style = style
    }
}
