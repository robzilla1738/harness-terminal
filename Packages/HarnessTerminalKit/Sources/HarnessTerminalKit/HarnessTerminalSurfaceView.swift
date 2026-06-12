import AppKit
import HarnessCopyMode
import HarnessCore
import HarnessTerminalEngine
import HarnessTerminalRenderer
import HarnessTheme
import Metal
import QuartzCore

// AppKit re-exports QuickDraw's legacy C `struct RGBColor`, which shadows
// `HarnessTheme.RGBColor` in this file. Pin the name to ours.
private typealias RGBColor = HarnessTheme.RGBColor

private struct SurfaceFrameBuildConfiguration: Sendable {
    var resolver: CellColorResolver
    var cursorColor: RGBColor
    var cursorTextColor: RGBColor?
    var canvasOpacity: Float
    var colorRendering: TerminalColorRenderingMode
    var colorGamut: TerminalColorGamut
    var cursorStyle: CursorStyle
    var selectionBackground: RGBColor?
    var selectionForeground: RGBColor?
    var promptGutterEnabled: Bool

    /// `reverseVideo` is per-build state (DECSET 5 can flip any time), not configuration —
    /// it rides the resolver copy so a build stays a pure function of (config, modes).
    func makeBuilder(reverseVideo: Bool = false) -> FrameBuilder {
        var resolver = self.resolver
        resolver.reverseVideo = reverseVideo
        return FrameBuilder(
            resolver: resolver,
            cursorColor: cursorColor,
            cursorTextColor: cursorTextColor,
            canvasOpacity: canvasOpacity,
            colorRendering: colorRendering,
            colorGamut: colorGamut,
            cursorStyle: cursorStyle,
            selectionBackground: selectionBackground,
            selectionForeground: selectionForeground,
            promptGutterEnabled: promptGutterEnabled
        )
    }
}

private struct SurfaceFrameBuildResult: Sendable {
    var generation: UInt64
    var frame: TerminalFrame
    var damage: TerminalDamage?
    /// Non-zero for a pure scrollback scroll: the frame is the previous one shifted by this many
    /// viewport rows (`FrameBuilder.buildShifted`), and the renderer should rotate its row cache
    /// by the same amount instead of re-encoding the kept rows. `damage` then lists exactly the
    /// newly-exposed rows.
    var scrollShift: Int = 0
    /// True when the frame carries the display-only smooth-scroll peek row: one extra row below
    /// the viewport (built whenever the view is scrolled into history) that the fraction translate
    /// reveals. The renderer clips it behind the grid box at fraction 0.
    var hasPeekRow: Bool = false
    var frameBuildNanos: UInt64
    var clearColor: RenderColor
}

private final class SurfaceColorProviderState: @unchecked Sendable {
    private let lock = NSLock()
    private var foreground = RGBColor(red: 255, green: 255, blue: 255)
    private var background = RGBColor(red: 0, green: 0, blue: 0)
    private var cursor = RGBColor(red: 255, green: 255, blue: 255)
    private var palette: [RGBColor] = []

    func update(foreground: RGBColor, background: RGBColor, cursor: RGBColor, palette: [RGBColor]) {
        lock.lock()
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.palette = palette
        lock.unlock()
    }

    func resolve(_ role: TerminalColorRole) -> (r: UInt8, g: UInt8, b: UInt8)? {
        lock.lock()
        defer { lock.unlock() }
        let c: RGBColor
        switch role {
        case .foreground: c = foreground
        case .background: c = background
        case .cursor: c = cursor
        case let .palette(i):
            guard i >= 0, i < palette.count else { return nil }
            c = palette[i]
        }
        return (c.red, c.green, c.blue)
    }
}

private final class SurfaceEmulatorState: @unchecked Sendable {
    private let specific = DispatchSpecificKey<Void>()

    let emulator: TerminalEmulator
    let queue: DispatchQueue
    var lastPlainFrame: TerminalFrame?
    /// The `renderGeneration` the cached `lastPlainFrame` was built against. The worker refuses to
    /// reuse a frame from a different generation, so a resize/theme/detach that bumps the generation
    /// (and resets the emulator/grid) can never diff new damage against a frame built for the old
    /// grid — which would show torn/stale rows. Belt-and-suspenders alongside `resetPlainFrame()`.
    var lastPlainFrameGeneration: UInt64 = 0
    /// Scroll-delta reuse source: the last overlay-free, image-free viewport frame (live at
    /// offset 0 or a scrolled history view), the scroll offset it was built at, and its
    /// generation. A pure scroll between two such frames rebuilds via
    /// `FrameBuilder.buildShifted` — re-resolving only the newly-exposed rows — instead of a
    /// full rebuild. Touched only on the serial queue (same discipline as `lastPlainFrame`).
    var lastViewportFrame: TerminalFrame?
    var lastViewportOffset = 0
    var lastViewportGeneration: UInt64 = 0
    /// Per-row fingerprints of the last build's cell-overlay pass (selection / find / IME
    /// preedit shading) — see `overlayRowKeys`. The next build re-encodes exactly the rows
    /// whose fingerprint changed, so a selection drag costs the rows it crossed, not the grid.
    /// Touched only on the serial queue (same discipline as `lastPlainFrame`).
    var lastOverlayKeys: [Int: UInt64] = [:]

    /// Latest-wins coalescing for async frame builds. Every `renderNowOffMain()` claims a token; a
    /// build whose token is no longer the latest (a newer build is already queued behind it on this
    /// serial queue) skips itself. The superseding build still sees all accumulated damage (the
    /// skipped build never called `consumeDamage`), so no rows are lost — a burst of marks coalesces
    /// to one build instead of N stale ones. Guarded by `tokenLock` because it's claimed on main and
    /// checked on the worker.
    private let tokenLock = NSLock()
    private var latestFrameToken: UInt64 = 0

    func claimFrameToken() -> UInt64 {
        tokenLock.lock(); defer { tokenLock.unlock() }
        latestFrameToken &+= 1
        return latestFrameToken
    }

    func isLatestFrameToken(_ token: UInt64) -> Bool {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return token == latestFrameToken
    }

    /// Separate token namespace for the live-resize preview builds. The preview must NOT share
    /// `latestFrameToken` with the output pipeline: during an ANIMATED resize (sidebar slide,
    /// tiling — no live-resize bracket, so output presents are not deferred) the two pipelines
    /// run concurrently, and a shared counter would let an output build silently cancel an
    /// in-flight re-wrap preview (and vice versa, dropping an echo frame). Each pipeline
    /// coalesces latest-wins against itself only.
    private var latestPreviewToken: UInt64 = 0

    func claimPreviewToken() -> UInt64 {
        tokenLock.lock(); defer { tokenLock.unlock() }
        latestPreviewToken &+= 1
        return latestPreviewToken
    }

    func isLatestPreviewToken(_ token: UInt64) -> Bool {
        tokenLock.lock(); defer { tokenLock.unlock() }
        return token == latestPreviewToken
    }

    /// Post-parse state one main hop applies to the main-thread mirrors (see `receiveOffMain`).
    /// `addedHistory` accumulates across coalesced chunks (the scroll anchor must advance by the
    /// TOTAL lines pushed into history, not the last chunk's delta); the rest are latest-wins —
    /// chunks merge in FIFO order on the emulator queue, so "latest" is the emulator's current
    /// state, which is exactly what the old one-hop-per-chunk delivery converged on.
    struct PendingMainHop {
        var addedHistory: Int
        var historyCount: Int
        var modes: TerminalModes
        var altScreen: Bool
    }

    /// Staged hop state + the "a main hop is in flight" flag, guarded by `tokenLock` (written on
    /// the worker, consumed on main). Invariant: whenever `pendingHop != nil`, exactly one
    /// `applyPendingMainHop` is queued or executing on main — `stageMainHop` returns true only
    /// to the chunk that transitions nil → non-nil, and that caller dispatches the hop.
    private var pendingHop: PendingMainHop?

    /// Merge this chunk's post-parse state into the staged hop. Returns true when the caller
    /// must dispatch a main hop (none is in flight); false when an already-queued hop will
    /// observe this state.
    func stageMainHop(addedHistory: Int, historyCount: Int, modes: TerminalModes, altScreen: Bool) -> Bool {
        tokenLock.lock(); defer { tokenLock.unlock() }
        if var hop = pendingHop {
            hop.addedHistory += addedHistory
            hop.historyCount = historyCount
            hop.modes = modes
            hop.altScreen = altScreen
            pendingHop = hop
            return false
        }
        pendingHop = PendingMainHop(
            addedHistory: addedHistory, historyCount: historyCount, modes: modes, altScreen: altScreen
        )
        return true
    }

    /// Consume the staged hop (main side). A chunk that lands after this re-arms a new hop.
    func takePendingMainHop() -> PendingMainHop? {
        tokenLock.lock(); defer { tokenLock.unlock() }
        defer { pendingHop = nil }
        return pendingHop
    }

    /// The latest grid size a resize commit requested, applied-and-cleared by the NEXT output/commit
    /// build to run on the queue (`applyPendingResize` at the top of `renderNowOffMain`'s build).
    /// Decoupling "which size to materialize" from "which build wins the latest-wins token" is what
    /// lets mid-drag output presents coexist with live-resize commits: an output build that
    /// supersedes an in-flight commit build (newer token → the commit skips before its resize)
    /// still carries the resize forward, so the emulator can never strand at the old size after
    /// the PTY vote went out. Touched ONLY on `queue` (the setters below dispatch there; the
    /// queue's FIFO orders a `setPendingResize` ahead of any build dispatched after it).
    private var pendingResize: (cols: Int, rows: Int)?

    /// Enqueue a resize target from main. The preview pipeline must never call the apply side —
    /// previews are non-mutating reads at an explicit target size.
    func setPendingResize(_ size: (cols: Int, rows: Int)) {
        queue.async { [self] in pendingResize = size }
    }

    /// Drop an unapplied target (detach/re-host: a stale size must not apply to a re-hosted view).
    func clearPendingResize() {
        queue.async { [self] in pendingResize = nil }
    }

    /// On-queue: materialize any pending resize and clear it. Idempotent across builds; returns
    /// whether the grid dimensions actually changed so the caller can drop its reuse caches.
    func applyPendingResize() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let size = pendingResize else { return false }
        pendingResize = nil
        emulator.resize(cols: size.cols, rows: size.rows)
        return true
    }

    /// Test seam: the staged-but-unapplied resize target (read on the queue).
    func pendingResizeForTesting() -> (cols: Int, rows: Int)? {
        sync { _ in pendingResize }
    }

    init(columns: Int, rows: Int) {
        self.emulator = TerminalEmulator(cols: columns, rows: rows)
        self.queue = DispatchQueue(label: "com.robert.harness.terminal-surface.emulator", qos: .userInteractive)
        queue.setSpecific(key: specific, value: ())
    }

    func sync<T>(_ body: (TerminalEmulator) -> T) -> T {
        if DispatchQueue.getSpecific(key: specific) != nil {
            return body(emulator)
        }
        return queue.sync {
            body(emulator)
        }
    }

    func async(_ body: @escaping @Sendable (TerminalEmulator) -> Void) {
        queue.async { [self] in
            body(emulator)
        }
    }

    func resetPlainFrame() {
        sync { _ in
            lastPlainFrame = nil
            lastViewportFrame = nil
            lastOverlayKeys = [:]
        }
    }
}

/// The native, self-contained terminal surface: a `CAMetalLayer`-backed `NSView` that
/// drives a `TerminalEmulator` and draws it with `TerminalMetalRenderer`. This is the
/// replacement for the previous renderer's view — bytes in via `receive(_:)`, input out
/// via `onInput`, grid-size changes via `onResize`.
///
/// Scope: GPU rendering with accurate sRGB output by default, opt-in converted Display-P3
/// vivid color, keyboard input, live resize, PTY responses (DSR/DA), mouse reporting,
/// selection, scrollback, copy mode, file-drop path insertion, IME, inline images, and
/// shell-integration marks.
@MainActor
public final class HarnessTerminalSurfaceView: NSView {
    private static let legacyFilenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private static let droppedPathPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        legacyFilenamesPasteboardType,
    ]

    static func droppedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        urls.append(contentsOf: objects.compactMap { object in
            if let url = object as? URL, url.isFileURL { return url }
            if let url = object as? NSURL, (url as URL).isFileURL { return url as URL }
            return nil
        })

        if let filenames = pasteboard.propertyList(forType: legacyFilenamesPasteboardType) as? [String] {
            urls.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
        }

        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    static func shellQuotedPath(_ path: String) -> String {
        ShellQuoting.quote(path)
    }

    static func droppedPathText(for urls: [URL]) -> String {
        urls.map { shellQuotedPath($0.path) }.joined(separator: " ")
    }

    /// Bytes the terminal produces for the PTY (typed input, key sequences, DSR/DA).
    public var onInput: ((Data) -> Void)?
    /// New grid size after a resize (columns, rows) — the host forwards this to the daemon.
    public var onResize: ((Int, Int) -> Void)?
    /// Fires while the grid size changes during a resize so the host can show a dimensions HUD.
    /// `committed` is false for the live (mid-drag) tick and true once the size settles. Never
    /// fires for the terminal's initial sizing live tick (opening a window isn't a resize).
    public var onGridSizeWillChange: ((_ cols: Int, _ rows: Int, _ committed: Bool) -> Void)?
    /// Fires when the scrollback position changes (wheel, page keys, jump-to-prompt) so the host
    /// can show a transient scrollbar. `topLine` is the buffer index of the top visible row,
    /// `totalLines` the whole buffer (history + viewport), `visibleRows` the viewport height.
    public var onScrollChanged: ((_ topLine: Int, _ totalLines: Int, _ visibleRows: Int) -> Void)?
    /// Window/tab title (OSC 0 / OSC 2) — the host forwards this to its delegate.
    public var onTitle: ((String) -> Void)?
    /// ConEmu progress report (OSC 9;4) — the host forwards this to its delegate, which
    /// drives the tab's working indicator (Claude Code 2.0+ keep-alives it per turn).
    public var onProgress: ((TerminalProgressReport) -> Void)?
    /// Reported working directory (OSC 7) — the host forwards this to its delegate.
    public var onPwd: ((String) -> Void)?
    /// OSC 1337 `SetUserVar=` (decoded + validated by the engine) — the host surfaces these
    /// as pane-scoped `@name` user options so format strings can read them.
    public var onUserVar: ((_ name: String, _ value: String) -> Void)?
    /// RIS dropped every user variable — the host clears the `@` options it pushed for
    /// this surface so `#{@name}` doesn't keep serving pre-reset values.
    public var onUserVarsCleared: (() -> Void)?
    /// Terminal bell (BEL) — the host forwards this to its delegate.
    public var onBell: (() -> Void)?
    /// A shell command finished (OSC 133), with its run duration + exit code — the host forwards
    /// this for the long-running-command-finished notification.
    public var onCommandFinished: ((_ duration: TimeInterval, _ exitCode: Int?) -> Void)?
    /// Desktop notification requested by a program (OSC 9 → nil title; OSC 777 → title+body)
    /// — the host forwards this to its delegate.
    public var onDesktopNotification: ((_ title: String?, _ body: String) -> Void)?
    /// This surface became effectively focused (first responder × key window). The host
    /// bridges it to the focus delegate so focusing a pane by click or app re-activation —
    /// not only a programmatic tab switch — clears its pending notification.
    public var onBecameFocused: (() -> Void)?
    /// Copied selection text — the host mirrors it into the daemon paste buffer (the
    /// system pasteboard is written here directly).
    public var onCopy: ((String) -> Void)?
    /// Optional per-frame renderer stats sink for diagnostics/benchmarks.
    public var onRenderStats: ((TerminalRenderStats) -> Void)?
    /// Whether a program may set the system clipboard via OSC 52 (tmux
    /// `set-clipboard`). The host sets this from the option; default on.
    public var allowProgramClipboardAccess = true

    private let emulatorState: SurfaceEmulatorState
    private let colorProviderState = SurfaceColorProviderState()
    private let inputEncoder = InputEncoder()
    private let metalLayer = CAMetalLayer()
    private var renderer: TerminalMetalRenderer?

    private var frameBuilder: FrameBuilder
    private var frameBuildConfiguration: SurfaceFrameBuildConfiguration
    private var colorRendering: TerminalColorRenderingMode
    private var colorGamut: TerminalColorGamut
    private var offMainParserFramePipelineEnabled = true // production default; always set from init
    private var renderGeneration: UInt64 = 0
    /// The last frame presented on the main thread, kept so a live resize can re-present it at the
    /// new drawable size WITHOUT touching the emulator serial queue (which, during heavy output, is
    /// busy parsing). During a drag the grid content is unchanged — reflow + SIGWINCH is debounced
    /// to drag-end (`scheduleResizeCommit`) — so stretching the last frame is exactly correct and
    /// never blocks main behind the parser. Main-thread only (written in `presentBuiltFrame`).
    private var lastPresentedResult: SurfaceFrameBuildResult?
    /// True when the renderer's row-instance cache verifiably holds exactly
    /// `lastPresentedResult.frame`'s rows — i.e. the last renderer encode was of that frame through
    /// the cache-updating path (non-nil damage, no images). Then `repaintLastFrame` can present with
    /// EMPTY damage and reuse every row (`encodedRows == 0`, zero-copy instance bind): under the
    /// drag-frozen origin all cache keys are stable, so the per-tick cost collapses to the viewport
    /// uniform + draw. Anything that lets the cache and the frame disagree — a preview replacing the
    /// frame without a present, a dropped present wiping the cache, an overlay/image frame bypassing
    /// it, a renderer rebuild — clears the flag, and the next repaint pays one cache-populating full
    /// rebuild before ticks turn free again. Main-thread only, like `lastPresentedResult`.
    private var lastPresentedResultIsRendererCoherent = false
    /// The (cols, rows) the live-resize preview was last built for, so a continuous drag rebuilds the
    /// re-wrap preview only when the cell count actually changes (sub-cell drag frames re-present the
    /// cached preview at the new drawable size). Reset on commit so the next drag starts fresh.
    private var previewCols = 0
    private var previewRows = 0
    /// Real-time live resize (Ghostty parity). When true, a window-edge drag commits the
    /// authoritative grid reflow + PTY `SIGWINCH` at every cell boundary so interactive programs
    /// (vim/htop/tmux) redraw continuously, instead of deferring the reflow to drag-end. The
    /// non-mutating re-wrap preview still rides under it for instant feedback. Set from
    /// `configureAppearance(liveResizeReflow:)`; the escape-hatch setting defaults it on. When
    /// false the surface keeps the legacy defer-to-release behavior.
    private var liveResizeReflowEnabled = true
    /// The (cols, rows) last handed to the PTY via `onResize`, so a mid-drag commit only fires a
    /// `SIGWINCH` when the cell count actually changed from the last one sent (a within-column drag
    /// frame sends nothing). Reset at drag end so the next drag starts fresh.
    private var lastSentPTYSize: (cols: Int, rows: Int)?
    private var fontFamily: String
    private var fontSize: CGFloat
    private var fontThicken: Bool
    private var fontThickenStrength: Int
    /// The canvas (default) background — used as the Metal clear color and (at
    /// `canvasOpacity`) for default-bg cells. Resolved by the host through the same
    /// `ThemeManager.resolvedCanvas` the chrome uses, so terminal and chrome never seam.
    private var canvasBackground: RGBColor
    /// 0...1. < 1 makes the canvas translucent (the window blur shows through); program
    /// output backgrounds and glyphs stay opaque.
    private var canvasOpacity: Float
    /// Window padding in points (`window-padding-x/y`); converted to device
    /// pixels and used both as the grid inset and the renderer's draw origin.
    private var paddingPointsX: CGFloat = 0
    private var paddingPointsY: CGFloat = 0
    /// Center the grid by splitting the sub-cell remainder onto both sides (`window-padding-balance`).
    private var paddingBalanced = true
    /// Device-pixel grid origin (padding × scale, plus the centering half-offset when balanced).
    /// Reused by `renderNow` as the draw origin and by mouse→cell mapping via `gridOriginPoints*`.
    private var originOffsetX = 0
    private var originOffsetY = 0
    /// The grid's left/top origin in points (device-px `originOffset` ÷ backing scale). Equals the
    /// window padding when unbalanced; when balanced it includes the centering half-offset, so
    /// mouse hit-testing, link-hover, and IME anchoring stay aligned with the centered grid.
    private var gridOriginPointsX: CGFloat { CGFloat(originOffsetX) / (window?.backingScaleFactor ?? 2.0) }
    private var gridOriginPointsY: CGFloat { CGFloat(originOffsetY) / (window?.backingScaleFactor ?? 2.0) }
    /// Cursor shape + blink (`cursor-style` / `cursor-style-blink`).
    private var cursorStyle: CursorStyle = .block
    private var cursorBlinkEnabled = true
    /// Blink phase: false hides the cursor on the off-beat. Reset to true on activity.
    private var cursorBlinkVisible = true
    private var blinkTimer: Timer?
    /// SGR text blink (`SGR 5`): phase driver for blinking CELLS, independent of the cursor
    /// timer (cursor blink follows focus; text blink follows content + visibility). Exists
    /// only while the last presented frame contained blink cells and the pane is visible.
    private var textBlinkTimer: Timer?
    private var textBlinkHidden = false
    /// Whether the most recently presented frame contained SGR-blink cells — drives
    /// `updateTextBlinkTimer` across occlusion changes without rescanning a frame.
    private var lastFrameHadBlink = false
    /// First-responder state — the cursor only blinks while focused.
    private var focused = false
    /// Whether the host window is key. Combined with `focused` for the user-visible focus
    /// state (hollow cursor, blink) and DECSET 1004 focus reporting — a first responder in a
    /// deactivated window is not focused.
    private var windowIsKey = false
    private var windowKeyObservers: [NSObjectProtocol] = []
    /// Last focus value reported via DECSET 1004, so window-key and first-responder
    /// transitions never double-report the same state.
    private var lastReportedFocus: Bool?
    private var effectivelyFocused: Bool { focused && windowIsKey }
    /// Mouse selection endpoints (anchor = where the drag started, head = current), in ABSOLUTE
    /// buffer coordinates: `line` is the virtual buffer line (copy mode's space — history first,
    /// then viewport; viewport row 0 = `historyCount - scrollOffset`). Content-anchored, not
    /// viewport-anchored, so the selection survives scrolling and new output (#161). A
    /// `SelectionRegion` is derived (expanded by granularity, rebased to viewport rows) for
    /// highlight + extraction.
    private var selectionAnchor: (line: Int, column: Int)?
    private var selectionHead: (line: Int, column: Int)?
    /// Selection unit set by click count: 1 = character, 2 = word, 3 = line. A drag extends by
    /// the unit; word/line ranges reuse copy-mode's word definition.
    private enum SelectionGranularity { case character, word, line }
    private var selectionGranularity: SelectionGranularity = .character
    /// Option-drag makes a rectangular (block) selection instead of a linear one.
    private var selectionRectangular = false
    private var selectionBackground: RGBColor?
    private var selectionForeground: RGBColor?
    /// Copy the selection to the pasteboard automatically when a drag ends.
    private var copyOnSelect = false
    /// Confirm before pasting risky (multi-line / control-char) text when bracketed paste is off.
    private var pasteProtection = true
    /// Mouse-wheel / trackpad scroll-distance multiplier (Ghostty `mouse-scroll-multiplier`).
    /// 1 = native. Set from `HarnessSettings.scrollMultiplier` (already clamped).
    var scrollMultiplier: CGFloat = 1
    /// Hide the cursor while typing until the mouse next moves (Ghostty `mouse-hide-while-typing`).
    var mouseHideWhileTyping = false
    var optionAsMeta: OptionAsMetaMode = .composed
    /// Scrollback offset in lines (0 = live bottom; >0 = scrolled up into history).
    private var scrollOffset = 0
    /// Smooth-scroll sub-line position. The continuous scrollback position is
    /// `P = scrollOffset - scrollFraction` (lines): the frame is built at the integer
    /// `scrollOffset = ceil(P)` — one line further back — and translated UP by
    /// `scrollFraction` of a cell at present time (a vertex-stage uniform; render-only, never
    /// baked into instances). The peek row fills the gap the translate opens at the bottom.
    /// Always 0 at the live bottom and whenever resting exactly on a line; every line-based
    /// consumer (hit-testing, copy mode, find, pinning, mouse reporting) keeps reading the
    /// integer `scrollOffset`.
    private var scrollFraction: CGFloat = 0
    /// Sub-line wheel remainder carried between scroll events so small trackpad movements
    /// accumulate into whole lines instead of each snapping a full line (see `consumeWheelLines`).
    private var wheelLineRemainder: CGFloat = 0
    /// Horizontal counterpart for mouse-reported wheel-left/right (see `consumeWheelColumns`).
    private var wheelColumnRemainder: CGFloat = 0
    /// Lines per notch for a discrete (non-precise) mouse wheel — the classic 3-line step.
    private static let mouseWheelLinesPerTick: CGFloat = 3
    /// Test-only: counts main-thread consume hops (one per `receiveOffMain` main bounce). The
    /// latency-under-load benchmark reads this to measure how aggressively the consume path
    /// coalesces a flood of small chunks. Never read in production; a single `Int` add on main.
    var testingMainHopCount = 0
    /// Canvas foreground — used to draw IME preedit (marked) text over the grid.
    private var canvasForeground: RGBColor = RGBColor(red: 255, green: 255, blue: 255)
    /// Resolved cursor + 16-color palette, surfaced to programs via OSC 10/11/12/4 *queries*
    /// (`emulator.colorProvider`) for light/dark theme detection.
    private var canvasCursor: RGBColor = RGBColor(red: 255, green: 255, blue: 255)
    private var ansiPalette16: [RGBColor] = []
    /// In-progress IME composition (preedit). Empty when not composing.
    private var markedText = ""
    /// Glyph coverage gamma: 1 = native blending; < 1 = gamma-correct (thicker) text.
    private var glyphGamma: Float = 1
    /// Programming-font ligatures via CoreText run shaping.
    private var ligaturesEnabled = true
    /// Draw the OSC 133 prompt gutter stripe. Off by default (a user opt-in).
    private var promptGutterEnabled = false

    private var columns: Int = 80
    private var rows: Int = 24
    /// The last frame built on the plain live path (no scrollback/selection/copy-mode/IME), kept
    /// so the next plain render can reuse unchanged rows via the engine's dirty-row damage. Set to
    /// nil whenever a non-plain frame is drawn or the appearance changes, forcing a full rebuild.
    private var lastPlainFrame: TerminalFrame?
    /// Coalesces renders to display cadence: `scheduleRender` marks dirty and wakes the link, which
    /// presents at most one frame per tick (resize/first paint/2026-timeout force immediately). Wired
    /// to `renderNow` in `init`.
    private lazy var scheduler = RenderScheduler(
        render: { [weak self] in self?.renderNow() },
        renderSynchronously: { [weak self] in self?.renderNowSynchronous() }
    )
    /// Main-thread display-cadence source (macOS 14+ `NSView.displayLink(target:selector:)`). Created
    /// when the view enters a window, paused while idle, invalidated on detach. nil when not in a
    /// window. Named `renderLink` so it doesn't shadow the `NSView.displayLink(...)` factory.
    private var renderLink: CADisplayLink?
    /// True once the grid has been sized from a real layout — the first sizing commits
    /// immediately (so the terminal opens at the right size); later changes coalesce.
    private var hasSizedGrid = false
    /// Pending coalesced grid+PTY resize. A sidebar slide / window drag calls `layout()`
    /// every frame; committing the grid reflow + PTY `SIGWINCH` each time storms the shell
    /// (fish/zsh redraw their prompt faster than they coalesce → overlapping garbage). The
    /// drawable still updates every frame for a smooth visual; the grid + PTY commit once the
    /// size settles.
    private var resizeCommitWork: DispatchWorkItem?
    /// Grid origin captured at `viewWillStartLiveResize`, held for the whole drag. Balanced
    /// padding re-centers the grid on *every* layout, so a pixel-by-pixel drag shifts the text
    /// ±1px per frame — a visible shimmer. Freezing the origin anchors the content for the
    /// duration (Ghostty's behavior: leftover sub-cell space accumulates at the right/bottom)
    /// and `viewDidEndLiveResize` re-centers exactly once for the settled size.
    private var liveResizeFrozenOrigin: (x: Int, y: Int)?
    /// Safety valve for DEC 2026 synchronized output: a program that enters a synchronized
    /// frame but never ends it must not freeze the display, so we force-present after this.
    private var syncTimeout: DispatchWorkItem?
    private let syncTimeoutInterval: TimeInterval = 0.15

    // MARK: Copy mode (in-pane overlay)
    /// Active copy-mode model (nil = not in copy mode). Driven by the shared
    /// `CopyModeReducer` over this view's own emulator (which holds the full scrollback), so
    /// the GUI overlay and the ssh compositor share one implementation.
    private var copyMode: CopyModeState?
    /// Merged copy-mode key tables (defaults + user `keybindings.json`), loaded on entry.
    private var copyModeTables: KeyTableSet?
    /// In-progress search query (nil = not entering a search). Shown in the status row.
    private var copyModeSearchEntry: String?
    /// Set while a jump-to-char motion (`f`/`F`/`t`/`T`) is waiting for its target keystroke.
    private var copyModeJumpEntry: CopyModeJumpKind?
    /// `mode-keys` option value (`vi` / `emacs`); the host sets it from the daemon option.
    public var copyModeKeys: String = "vi"
    public var isInCopyMode: Bool { copyMode != nil }

    // MARK: Find (in-scrollback search bar)
    /// True while the Cmd+F find bar is open; gates highlight rendering + scroll-to-match.
    private var findActive = false
    /// All matches for the current query, in buffer-line order (history + viewport space).
    private var findMatches: [TerminalBufferMatch] = []
    /// Index of the "current" match within `findMatches` (the one we scrolled to).
    private var findCurrentIndex = 0
    /// Reports `(current, total)` to the host so the find bar can show "n of m" (0,0 = none).
    public var onFindResultsChanged: ((_ current: Int, _ total: Int) -> Void)?

    // MARK: Link hover (⌘-hover affordance for ⌘-click open)
    /// The link span under the pointer while ⌘ is held: a grid row + half-open column range.
    /// Drives the underline layer and the pointing-hand cursor. nil when not hovering a link.
    private var hoveredLink: (row: Int, columns: Range<Int>)?
    /// Underline drawn beneath the hovered link. A sublayer of the Metal layer so it composites
    /// above the terminal content without intercepting clicks (a subview would eat the ⌘-click).
    private let linkUnderlineLayer = CALayer()
    /// Visual-bell flash: a full-surface translucent layer composited above the terminal content,
    /// faded out in one shot by `flashBell()`. Hidden at rest so it never affects normal rendering.
    private let bellFlashLayer = CALayer()
    /// Bumped per `flashBell()` so a flash that restarts mid-fade doesn't get hidden by the older
    /// animation's completion block.
    private var bellFlashGeneration: UInt64 = 0
    private var trackingArea: NSTrackingArea?

    public init(
        themeName: String = ThemeManager.defaultThemeName,
        fontFamily: String = "Menlo",
        fontSize: CGFloat = 14,
        vivid: Bool = false,
        colorRendering: TerminalColorRenderingMode? = nil,
        colorGamut: TerminalColorGamut = .auto,
        offMainParserFramePipeline: Bool = true,
        liveResizeReflow: Bool = true
    ) {
        let theme = HarnessThemeCatalog.theme(named: themeName)
            ?? HarnessThemeCatalog.theme(named: ThemeManager.defaultThemeName)!
        let resolvedColorRendering = colorRendering ?? (vivid ? .vivid : .accurate)
        let resolvedGamut = TerminalColorGamut.resolved(
            renderingMode: resolvedColorRendering,
            requested: colorGamut
        )
        let resolver = CellColorResolver(theme: theme)
        // Baseline appearance; the host immediately overrides via configureAppearance.
        self.frameBuilder = FrameBuilder(
            resolver: resolver,
            cursorColor: theme.cursor ?? theme.foreground,
            cursorTextColor: theme.cursorText,
            colorRendering: resolvedColorRendering,
            colorGamut: resolvedGamut
        )
        self.frameBuildConfiguration = SurfaceFrameBuildConfiguration(
            resolver: resolver,
            cursorColor: theme.cursor ?? theme.foreground,
            cursorTextColor: theme.cursorText,
            canvasOpacity: 1,
            colorRendering: resolvedColorRendering,
            colorGamut: resolvedGamut,
            cursorStyle: .block,
            selectionBackground: nil,
            selectionForeground: nil,
            promptGutterEnabled: true
        )
        self.canvasBackground = theme.background
        self.canvasOpacity = 1
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.fontThicken = false
        self.fontThickenStrength = 255
        self.colorRendering = resolvedColorRendering
        self.colorGamut = resolvedGamut
        self.offMainParserFramePipelineEnabled = offMainParserFramePipeline
        self.liveResizeReflowEnabled = liveResizeReflow
        self.emulatorState = SurfaceEmulatorState(columns: columns, rows: rows)
        super.init(frame: .zero)
        registerForDraggedTypes(Self.droppedPathPasteboardTypes)
        colorProviderState.update(
            foreground: theme.foreground,
            background: theme.background,
            cursor: theme.cursor ?? theme.foreground,
            palette: theme.palette
        )
        configureLayer()
        configureEmulatorCallbacks()
        // Defer the renderer build: at init the view has no window, so
        // `window?.backingScaleFactor` would fall back to 2.0 and compile the Metal
        // pipeline at the wrong scale — work immediately thrown away when the host
        // calls `configureAppearance` and again at `viewDidMoveToWindow` (real scale).
        // Every render/layout path guards `renderer == nil`, and the first real render
        // only happens once the view is in a window, so building there is correct and
        // avoids a discarded shader/pipeline compile per surface.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: - Public API

    /// Feed PTY output bytes into the emulator and schedule a redraw.
    public func receive(_ data: Data) { receive(data, replay: false) }

    /// `replay: true` marks persisted-scrollback bytes fed on (re)attach: they restore state but
    /// must not re-fire world-facing effects (query replies to the PTY, bells, notifications,
    /// clipboard writes — see `TerminalEmulator.isReplaying`). The flag brackets exactly this
    /// chunk's `feed` on the emulator's serialized context.
    public func receive(_ data: Data, replay: Bool) {
        if offMainParserFramePipelineEnabled {
            receiveOffMain(data, replay: replay)
            return
        }
        let beforeHistory = emulatorState.emulator.historyCount
        if replay { emulatorState.emulator.isReplaying = true }
        emulatorState.emulator.feed(data)
        if replay { emulatorState.emulator.isReplaying = false }
        // If the user is scrolled up, stay anchored on the same content as new lines push
        // into history; at the bottom (offset 0) we naturally follow new output.
        if scrollOffset > 0 {
            let added = emulatorState.emulator.historyCount - beforeHistory
            if added > 0 { scrollOffset = min(emulatorState.emulator.historyCount, scrollOffset + added) }
        }
        wakeCursor()
        // DEC 2026 synchronized output: hold the last presented frame while the program is
        // mid-update (no tearing), and present atomically the moment it ends the batch — which
        // is exactly when this chunk leaves `synchronizedOutput` false. A timeout guards a
        // program that never closes the update.
        if emulatorState.emulator.modes.synchronizedOutput {
            scheduler.setSynchronized(true) // hold the display tick mid-batch (no tearing)
            armSyncTimeout()
        } else {
            syncTimeout?.cancel(); syncTimeout = nil
            // Releasing 2026 marks dirty; the batched frame presents atomically at the next tick.
            scheduler.setSynchronized(false)
            wakeDisplayLink()
            // Low-latency echo: present this chunk now instead of waiting up to a full display
            // interval. Coalesced to one paint per interval during a burst by the scheduler.
            scheduler.presentNow()
        }
    }

    private func receiveOffMain(_ data: Data, replay: Bool = false) {
        emulatorState.async { [weak self] emulator in
            guard let self else { return }
            let beforeHistory = emulator.historyCount
            if replay { emulator.isReplaying = true }
            FrameSignposter.shared.interval("parse") { emulator.feed(data) }
            if replay { emulator.isReplaying = false }
            let afterHistory = emulator.historyCount
            // Coalesce the main hop: under a flood, per-chunk main.async was tens of thousands
            // of dispatches/sec of pure scheduling tax on the main thread. Each chunk merges its
            // post-parse state into the staged hop; only the chunk that finds no hop in flight
            // dispatches one, and the hop reads the LATEST staged state when it runs — so the
            // mirrors converge exactly as the old one-hop-per-chunk delivery did, in (at most)
            // one main dispatch per main-thread turn instead of one per chunk. A lone keystroke
            // echo on an idle surface still gets its immediate hop + presentNow.
            // Only positive history deltas advance the scroll anchor (matching the old per-chunk
            // `added > 0` guard); shrinks (clear/alt-screen) are clamped by `historyCount`.
            let needsHop = self.emulatorState.stageMainHop(
                addedHistory: max(0, afterHistory - beforeHistory),
                historyCount: afterHistory,
                modes: emulator.modes,
                altScreen: emulator.isAlternateScreenActive
            )
            guard needsHop else { return }
            FrameSignposter.shared.event("mainHop")
            DispatchQueue.main.async { [weak self] in
                self?.applyPendingMainHop()
            }
        }
    }

    /// Apply the staged post-parse state to the main-thread mirrors and the render scheduler.
    /// Runs on main; no-op when a concurrent flush (`testingWaitForEmulatorIdle`) already
    /// consumed the hop.
    private func applyPendingMainHop() {
        guard let hop = emulatorState.takePendingMainHop() else { return }
        testingMainHopCount &+= 1
        // Refresh the input-side mirror (see `inputModes()`); chunks merge in FIFO order on the
        // emulator queue, so the staged state is always the emulator's latest.
        inputModesMirror = hop.modes
        altScreenMirror = hop.altScreen
        historyCountMirror = hop.historyCount
        if scrollOffset > 0, hop.addedHistory > 0 {
            scrollOffset = min(hop.historyCount, scrollOffset + hop.addedHistory)
        }
        wakeCursor()
        if hop.modes.synchronizedOutput {
            scheduler.setSynchronized(true)
            armSyncTimeout()
        } else {
            syncTimeout?.cancel(); syncTimeout = nil
            scheduler.setSynchronized(false)
            wakeDisplayLink()
            // Low-latency echo (off-main): kick the frame build now rather than at the next
            // tick. renderNowOffMain builds on the emulator queue and presents on main; the
            // renderGeneration guard drops any stale build so there's no double present.
            scheduler.presentNow()
        }
    }

    private func armSyncTimeout() {
        guard syncTimeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.syncTimeout = nil
            // Safety valve: a program that set 2026 but never cleared it must not freeze the
            // display, so force-present past the hold.
            self?.scheduler.forceRender()
        }
        syncTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + syncTimeoutInterval, execute: work)
    }

    public func receive(_ text: String) { receive(Data(text.utf8)) }

    public func receive(_ text: String, replay: Bool) { receive(Data(text.utf8), replay: replay) }

    func testingReadGridSnapshot() -> TerminalGridSnapshot {
        emulatorSync { $0.readGrid() }
    }

    func testingWaitForEmulatorIdle() {
        // Drain the parse queue AND apply any staged main hop — tests call this in place of
        // spinning the runloop, so the mirrors (incl. modes/alt-screen, smooth scrolling clamps
        // against `historyCountMirror`) must not lag the drained state. The already-queued
        // main.async hop then no-ops (the hop was consumed here).
        let history = emulatorState.sync { $0.historyCount }
        applyPendingMainHop()
        historyCountMirror = history
    }

    func testingInputModes() -> TerminalModes { inputModes() }

    /// Test seam: drive the window-key half of `effectivelyFocused` (the real value comes from
    /// `NSWindow` key-state notifications, which are awkward to trigger headlessly). Mirrors the
    /// `didBecomeKey`/`didResignKey` observers — set the flag, then re-evaluate focus state.
    func testingSetWindowIsKey(_ isKey: Bool) {
        windowIsKey = isKey
        focusStateChanged()
    }

    func testingResizeGrid(cols: Int, rows: Int) {
        commitGridSize(cols: cols, rows: rows)
        // The commit stages the reflow for the next output/commit build to materialize; headless
        // there is no renderer, so no build ever runs — apply the staged target directly (the
        // exact step the first build performs) so tests observe the resize synchronously.
        emulatorState.sync { _ in _ = emulatorState.applyPendingResize() }
    }

    var testingRenderSynchronized: Bool { scheduler.synchronized }
    var testingRenderPending: Bool { scheduler.needsRender }
    var testingFontThickenConfiguration: (enabled: Bool, strength: Int) {
        (fontThicken, fontThickenStrength)
    }

    // Live-resize seams (glitchless-resize behavior is asserted headlessly: no window, no Metal).
    var testingPresentsWithTransaction: Bool { metalLayer.presentsWithTransaction }
    var testingLiveResizeFrozenOrigin: (x: Int, y: Int)? { liveResizeFrozenOrigin }
    var testingGridSize: (cols: Int, rows: Int) { (columns, rows) }
    var testingHasPendingResizeCommit: Bool { resizeCommitWork != nil }
    func testingScheduleResizeCommit(cols: Int, rows: Int) { scheduleResizeCommit(cols: cols, rows: rows) }
    func testingRequestLiveResizeCommit(cols: Int, rows: Int) { requestLiveResizeCommit(cols: cols, rows: rows) }
    func testingSetLiveResizeReflow(_ enabled: Bool) { liveResizeReflowEnabled = enabled }
    var testingLiveResizeReflowEnabled: Bool { liveResizeReflowEnabled }
    var testingLastSentPTYSize: (cols: Int, rows: Int)? { lastSentPTYSize }
    func testingMarkGridSized() { hasSizedGrid = true }
    // pendingResize seams: the staged-but-unapplied reflow target, a direct driver for the
    // scheduler's async off-main entry (what a PTY output burst triggers mid-drag), and a queue
    // gate for staging deterministic build interleavings (e.g. an output build superseding a
    // commit build's frame token while both sit queued).
    var testingPendingResize: (cols: Int, rows: Int)? { emulatorState.pendingResizeForTesting() }
    func testingRenderNowOffMainAsync() { renderNowOffMain() }
    func testingBlockEmulatorQueue(until gate: DispatchSemaphore) {
        emulatorState.async { _ in gate.wait() }
    }
    // Window-hosted seams (the routing test drives real presents through a real Metal renderer).
    var testingOriginOffset: (x: Int, y: Int) { (originOffsetX, originOffsetY) }
    var testingHasRenderer: Bool { renderer != nil }
    var testingLastPresentScheduleNanos: UInt64 { renderer?.stats.presentScheduleNanos ?? 0 }
    // Full renderer stats for the frame-pacing harness (encodedRows/reusedRows/uploadBytes/...).
    var testingLastRenderStats: TerminalRenderStats? { renderer?.stats }
    var testingRepaintCacheCoherent: Bool { lastPresentedResultIsRendererCoherent }
    func testingRepaintLastFrame() -> Bool { repaintLastFrame() }
    // Async resize-preview seams: the current drag target the next landing preview must match,
    // and the renderer's device-pixel cell metrics (for stepping exactly one cell in benchmarks).
    var testingPreviewTarget: (cols: Int, rows: Int) { (previewCols, previewRows) }
    var testingCellPixelSize: (width: Int, height: Int) {
        (renderer?.cellPixelWidth ?? 0, renderer?.cellPixelHeight ?? 0)
    }
    /// Drive `presentResizePreview` directly with explicit (possibly stale) args — the main-hop
    /// guards only fire under racy interleavings production tests can't stage deterministically.
    /// Builds the preview synchronously, then lands it with the given token/target. Returns
    /// whether it was accepted (false = the guards dropped it).
    func testingPresentResizePreview(cols: Int, rows: Int, token: UInt64) -> Bool {
        let config = frameBuildConfiguration
        let bg = canvasBackground
        let fg = canvasForeground
        let opacity = canvasOpacity
        let generation = renderGeneration
        let result: SurfaceFrameBuildResult? = emulatorState.sync { emulator in
            guard let preview = emulator.previewViewportReflow(cols: cols, rows: rows) else { return nil }
            let reverseVideo = emulator.modes.reverseVideo
            let builder = config.makeBuilder(reverseVideo: reverseVideo)
            let frame = builder.build(preview, region: nil, imageProvider: { emulator.image(for: $0) })
            return SurfaceFrameBuildResult(
                generation: generation, frame: frame, damage: nil,
                frameBuildNanos: 0, clearColor: builder.renderColor(reverseVideo ? fg : bg, alpha: opacity)
            )
        }
        guard let result else { return false }
        return presentResizePreview(result, cols: cols, rows: rows, token: token)
    }
    func testingClaimPreviewToken() -> UInt64 { emulatorState.claimPreviewToken() }
    var testingRenderGeneration: UInt64 { renderGeneration }
    /// Neutralize the armed 60ms resize-commit debounce (matches `viewDidEndLiveResize`'s cancel
    /// semantics) so timing-sensitive assertions don't race it.
    func testingCancelPendingResizeCommit() {
        resizeCommitWork?.cancel()
        resizeCommitWork = nil
    }
    // Scroll-reuse seams: drive a synchronous build+present and a scrollback scroll headlessly.
    func testingForceRender() { scheduler.forceRender() }
    /// Programmatic selection for the cell-overlay tests (a mouse drag's end state). Takes
    /// VIEWPORT rows like a real drag and converts to the absolute buffer anchors `mouseDown`
    /// would store.
    func testingSetSelection(
        anchor: (row: Int, column: Int)?, head: (row: Int, column: Int)?, rectangular: Bool = false
    ) {
        let top = viewportTopBufferLine
        selectionAnchor = anchor.map { (line: top + $0.row, column: $0.column) }
        selectionHead = head.map { (line: top + $0.row, column: $0.column) }
        selectionRectangular = rectangular
        selectionGranularity = .character
        scheduleRender()
    }
    /// The active selection's extracted text (nil when nothing is selected) — the #161 seam:
    /// content-anchored selections must extract the same text before and after scrolling.
    func testingSelectionText() -> String? { selectionTextIfAny() }
    func testingSetSelectionColors(
        background: HarnessTheme.RGBColor?, foreground: HarnessTheme.RGBColor?
    ) {
        selectionBackground = background
        frameBuildConfiguration.selectionBackground = background
        frameBuildConfiguration.selectionForeground = foreground
    }
    func testingMakeFrameBuilder() -> FrameBuilder { frameBuildConfiguration.makeBuilder() }
    var testingLastPresentedFrame: TerminalFrame? { lastPresentedResult?.frame }
    var testingLastPresentedDamage: TerminalDamage? { lastPresentedResult?.damage }
    func testingSetWindowOccluded(_ occluded: Bool) { setWindowOccluded(occluded) }
    var testingIsOccluded: Bool { scheduler.isOccluded }
    // Smooth-scroll seams: continuous (sub-line) scrolling and the resulting offset/fraction split.
    func testingScrollByContinuous(lines: CGFloat) { scrollByContinuous(lines: lines) }
    var testingScrollPosition: (offset: Int, fraction: CGFloat) { (scrollOffset, scrollFraction) }
    // Drive one display-cadence tick (the scheduler's ASYNC render entry — the path the live-drag
    // hold defers); tests use it where the real CADisplayLink would fire.
    @discardableResult
    func testingSchedulerTick() -> Bool { scheduler.tick() }
    func testingScrollBy(lines: Int) { scrollBy(lines: lines) }

    /// The full appearance the host computes from settings + theme:
    /// - `canvasBackground/Foreground/cursor` come from `ThemeManager.resolvedCanvas`, so
    ///   the terminal canvas matches the chrome (no seam) regardless of theme-output mode.
    /// - `outputPalette` is the 16 ANSI colors for *program output*: the theme palette when
    ///   "apply theme to output" is on, otherwise the untouched default palette.
    /// - `canvasOpacity` < 1 makes the canvas translucent for the window blur.
    /// Rebuilds the renderer/atlas (font/colorspace) and the color resolver.
    public func configureAppearance(
        fontFamily: String,
        fontSize: CGFloat,
        vivid: Bool,
        colorRendering: TerminalColorRenderingMode? = nil,
        colorGamut: TerminalColorGamut = .auto,
        canvasBackgroundHex: String,
        canvasForegroundHex: String,
        cursorHex: String,
        outputPaletteHex: [String?],
        oscPaletteHex: [String?]? = nil,
        canvasOpacity: Float,
        cursorStyle: String,
        cursorBlink: Bool,
        paddingX: CGFloat,
        paddingY: CGFloat,
        paddingBalance: Bool = true,
        selectionBackgroundHex: String?,
        selectionForegroundHex: String?,
        cursorTextHex: String? = nil,
        copyOnSelect: Bool,
        pasteProtection: Bool = true,
        scrollbackLines: Int,
        linearBlending: Bool,
        textRendering: TerminalTextRenderingMode? = nil,
        ligatures: Bool,
        minimumContrast: Double = 1,
        boldIsBright: Bool = true,
        promptGutter: Bool = false,
        offMainParserFramePipeline: Bool = true,
        liveResizeReflow: Bool = true
    ) {
        liveResizeReflowEnabled = liveResizeReflow
        emulatorSync { $0.maxScrollbackLines = scrollbackLines }
        if offMainParserFramePipelineEnabled && !offMainParserFramePipeline {
            // Drain any queued parser/frame work before direct main-thread emulator access resumes.
            emulatorState.sync { _ in }
        }
        if offMainParserFramePipelineEnabled != offMainParserFramePipeline {
            offMainParserFramePipelineEnabled = offMainParserFramePipeline
            invalidateRenderGeneration()
        }
        let resolvedColorRendering = colorRendering ?? (vivid ? .vivid : .accurate)
        let resolvedGamut = TerminalColorGamut.resolved(
            renderingMode: resolvedColorRendering,
            requested: colorGamut
        )
        let resolvedTextRendering = textRendering ?? (linearBlending ? .crisp : .native)
        glyphGamma = resolvedTextRendering.glyphGamma
        fontThicken = resolvedTextRendering == .crisp
        fontThickenStrength = 255
        ligaturesEnabled = ligatures
        promptGutterEnabled = promptGutter
        let bg = RGBColor(hex: canvasBackgroundHex) ?? RGBColor(red: 0, green: 0, blue: 0)
        let fg = RGBColor(hex: canvasForegroundHex) ?? RGBColor(red: 255, green: 255, blue: 255)
        let cursor = RGBColor(hex: cursorHex) ?? fg
        // Selection background: explicit setting/theme value, else a neutral slate.
        let selBg = selectionBackgroundHex.flatMap { RGBColor(hex: $0) }
            ?? RGBColor(red: 68, green: 78, blue: 102)
        let selFg = selectionForegroundHex.flatMap { RGBColor(hex: $0) }
        // Cursor-text (the glyph under a block cursor); nil falls back to the canvas bg.
        let cursorText = cursorTextHex.flatMap { RGBColor(hex: $0) }
        // 16 ANSI colors for program output; nil slots fall back to the default palette.
        let palette: [RGBColor] = (0 ..< 16).map { i in
            let hex = (i < outputPaletteHex.count ? outputPaletteHex[i] : nil)
                ?? ThemeManager.defaultBaselinePaletteHex[i]
            return RGBColor(hex: hex) ?? RGBColor(red: 0, green: 0, blue: 0)
        }
        let queryPalette: [RGBColor] = (0 ..< 16).map { i in
            let hex = (oscPaletteHex.flatMap { i < $0.count ? $0[i] : nil })
                ?? (i < outputPaletteHex.count ? outputPaletteHex[i] : nil)
                ?? ThemeManager.defaultBaselinePaletteHex[i]
            return RGBColor(hex: hex) ?? RGBColor(red: 0, green: 0, blue: 0)
        }
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.colorRendering = resolvedColorRendering
        self.colorGamut = resolvedGamut
        self.canvasBackground = bg
        self.canvasForeground = fg
        self.canvasCursor = cursor
        self.ansiPalette16 = palette
        self.canvasOpacity = max(0, min(1, canvasOpacity))
        self.cursorStyle = CursorStyle(rawValue: cursorStyle) ?? .block
        self.cursorBlinkEnabled = cursorBlink
        self.paddingPointsX = max(0, paddingX)
        self.paddingPointsY = max(0, paddingY)
        self.paddingBalanced = paddingBalance
        self.selectionBackground = selBg
        self.selectionForeground = selFg
        self.copyOnSelect = copyOnSelect
        self.pasteProtection = pasteProtection
        colorProviderState.update(foreground: fg, background: bg, cursor: cursor, palette: queryPalette)
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: palette),
            defaultForeground: fg,
            defaultBackground: bg,
            boldBrightens: boldIsBright,
            minimumContrast: minimumContrast
        )
        self.frameBuildConfiguration = SurfaceFrameBuildConfiguration(
            resolver: resolver,
            cursorColor: cursor,
            cursorTextColor: cursorText,
            canvasOpacity: self.canvasOpacity,
            colorRendering: resolvedColorRendering,
            colorGamut: resolvedGamut,
            cursorStyle: self.cursorStyle,
            selectionBackground: selBg,
            selectionForeground: selFg,
            promptGutterEnabled: promptGutterEnabled
        )
        self.frameBuilder = FrameBuilder(
            resolver: resolver,
            cursorColor: cursor,
            cursorTextColor: cursorText,
            canvasOpacity: self.canvasOpacity,
            colorRendering: resolvedColorRendering,
            colorGamut: resolvedGamut,
            cursorStyle: self.cursorStyle,
            selectionBackground: selBg,
            selectionForeground: selFg,
            promptGutterEnabled: promptGutterEnabled
        )
        // Resolved colors/opacity changed — cached rows hold the old palette; force a full rebuild.
        lastPlainFrame = nil
        emulatorState.resetPlainFrame()
        invalidateRenderGeneration()
        restartBlinkTimer()
        // Opaque only when fully opaque; otherwise the layer must be non-opaque so the
        // window-wide blur shows through the translucent canvas.
        metalLayer.isOpaque = self.canvasOpacity >= 1
        metalLayer.colorspace = CGColorSpace(name: layerColorSpaceName)
        buildRenderer()
        updateGridSize()
        scheduleRender()
    }

    // MARK: - Setup

    private func emulatorSync<T>(_ body: (TerminalEmulator) -> T) -> T {
        if offMainParserFramePipelineEnabled {
            return emulatorState.sync(body)
        }
        return body(emulatorState.emulator)
    }

    /// Snapshot the buffer text + cursor position for the accessibility (VoiceOver) layer, taken
    /// atomically under the one emulator-access seam. Lives here (not the `+Accessibility` extension)
    /// because `emulatorSync` is file-private. Lines are the full scrollback + screen, so VoiceOver
    /// can review history; the cursor line is offset past the scrollback so it indexes those lines.
    func accessibilitySnapshot() -> (lines: [String], cursorLine: Int, cursorColumn: Int) {
        emulatorSync { emulator in
            let cursor = emulator.readGrid().cursor
            return (emulator.captureLines(joinWrapped: false), emulator.historyCount + cursor.row, cursor.col)
        }
    }

    /// Main-thread mirror of the emulator state the *input* paths need (key/mouse/paste encoding),
    /// refreshed by every parsed chunk's main hop in `receiveOffMain`. Reading the mirror keeps a
    /// keystroke from doing a `queue.sync` against the parser — a held arrow key must never stall
    /// the main thread behind a busy parse. At most one in-flight chunk stale, the same window the
    /// old synchronous read had (those bytes were simply still unparsed then). Defaults match a
    /// fresh `TerminalEmulator`, so reads before the first output are correct.
    private var inputModesMirror = TerminalModes()
    private var altScreenMirror = false
    /// History line count, same mirror discipline: smooth scrolling clamps against it on EVERY
    /// precise wheel event (sub-line deltas included), so the clamp must not `queue.sync` behind
    /// a busy parse — that per-event stall is the scroll-jank class. At most one chunk stale;
    /// history only moves via parsed output, and the output-pinning hop re-aligns the offset with
    /// the real count anyway, so a momentarily-short clamp self-corrects on the next event.
    private var historyCountMirror = 0

    /// The terminal modes input encoding should honor right now (mirror on the off-main pipeline;
    /// direct read when the emulator lives on main).
    private func inputModes() -> TerminalModes {
        offMainParserFramePipelineEnabled ? inputModesMirror : emulatorState.emulator.modes
    }

    /// Whether the alternate screen is active, for input-side decisions (alternate scroll).
    private func inputAltScreenActive() -> Bool {
        offMainParserFramePipelineEnabled ? altScreenMirror : emulatorState.emulator.isAlternateScreenActive
    }

    private func invalidateRenderGeneration() {
        renderGeneration &+= 1
        emulatorState.resetPlainFrame()
        lastPresentedResultIsRendererCoherent = false
        // The blink-scan cache describes the last PRESENTED frame; invalidation makes that
        // frame garbage (theme/font change, window detach), so the occlusion path must not
        // re-arm the text-blink timer from it. Conservative false — every invalidating site
        // schedules a render, and that present recomputes the truth.
        lastFrameHadBlink = false
    }

    private func configureLayer() {
        // Layer-hosting: assign the custom layer before enabling wantsLayer.
        layer = metalLayer
        wantsLayer = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = TerminalMetalRenderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // Double-buffer (default is 3): triple-buffering adds up to one extra frame of swap latency,
        // which matters for keystroke echo. 2 still lets the next frame render while the current one
        // scans out. Kept in lockstep with the renderer's `maxFramesInFlight` (also 2) so the in-flight
        // semaphore and the drawable pool advertise the same depth — a deeper semaphore would just
        // block on `nextDrawable()` anyway. Keep `allowsNextDrawableTimeout` on (the default): both
        // render paths run `nextDrawable()` on the main thread/queue, so disabling the timeout would
        // let a fully occluded window or a stalled GPU block the main thread indefinitely (frozen
        // input + UI). With the timeout, a stall returns nil after ~1s; both paths re-arm the scheduler
        // on nil so the next display tick simply retries — nothing is lost, and main never wedges.
        metalLayer.maximumDrawableCount = 2
        metalLayer.allowsNextDrawableTimeout = true
        // Pin the grid to the top-left so any sub-cell remainder from flooring rows/cols
        // parks at the bottom-right instead of being centered into a hairline seam at the
        // top edge during live resize.
        metalLayer.contentsGravity = .topLeft
        // Tag the layer to match the frame builder's RGB output. Accurate mode stays sRGB;
        // vivid mode converts authored sRGB into Display-P3 before tagging the layer P3.
        metalLayer.colorspace = CGColorSpace(name: layerColorSpaceName)
        // Link-hover underline: a thin sublayer composited above the terminal content.
        linkUnderlineLayer.isHidden = true
        linkUnderlineLayer.backgroundColor = NSColor.linkColor.cgColor
        metalLayer.addSublayer(linkUnderlineLayer)
        // Visual-bell flash: a full-surface sublayer above the content, hidden at rest.
        bellFlashLayer.isHidden = true
        bellFlashLayer.opacity = 0
        metalLayer.addSublayer(bellFlashLayer)
    }

    /// Visual bell — a brief theme-foreground flash over the surface (the `visual` channel of the
    /// `bellMode` setting / tmux `visual-bell`). Composites a translucent sublayer above the Metal
    /// content and fades it out; the terminal content underneath is untouched. Re-entrant safe: a
    /// second bell mid-fade just restarts the animation. Must be called on the main thread.
    public func flashBell() {
        let c = canvasForeground
        let flash = CGColor(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255,
                            blue: CGFloat(c.blue) / 255, alpha: 1)
        // Set geometry + color with implicit animation disabled, then run one explicit fade so a
        // resize-driven implicit bounds animation can't blur the flash.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bellFlashLayer.frame = bounds
        bellFlashLayer.backgroundColor = flash
        bellFlashLayer.isHidden = false
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.28 // peak: visible but not a jarring full-white blink
        fade.toValue = 0
        fade.duration = 0.16
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.isRemovedOnCompletion = true
        let token = bellFlashGeneration &+ 1
        bellFlashGeneration = token
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            // Only hide if no newer flash superseded this one (avoid hiding mid-restart).
            guard let self, self.bellFlashGeneration == token else { return }
            self.bellFlashLayer.isHidden = true
        }
        bellFlashLayer.opacity = 0
        bellFlashLayer.add(fade, forKey: "bellFlash")
        CATransaction.commit()
    }

    private var layerColorSpaceName: CFString {
        switch colorGamut {
        case .displayP3: return CGColorSpace.displayP3
        case .sRGB, .auto: return CGColorSpace.sRGB
        }
    }

    private func configureEmulatorCallbacks() {
        let emulator = emulatorState.emulator
        emulator.onResponse = { [weak self] data in
            if Thread.isMainThread {
                self?.onInput?(data)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onInput?(data) }
            }
        }
        emulator.onTitleChange = { [weak self] title in
            if Thread.isMainThread {
                self?.onTitle?(title)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onTitle?(title) }
            }
        }
        emulator.onProgress = { [weak self] report in
            if Thread.isMainThread {
                self?.onProgress?(report)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onProgress?(report) }
            }
        }
        emulator.onWorkingDirectoryChange = { [weak self] path in
            if Thread.isMainThread {
                self?.onPwd?(path)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onPwd?(path) }
            }
        }
        emulator.onUserVariableChange = { [weak self] name, value in
            if Thread.isMainThread {
                self?.onUserVar?(name, value)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onUserVar?(name, value) }
            }
        }
        emulator.onUserVariablesCleared = { [weak self] in
            if Thread.isMainThread {
                self?.onUserVarsCleared?()
            } else {
                DispatchQueue.main.async { [weak self] in self?.onUserVarsCleared?() }
            }
        }
        emulator.onBell = { [weak self] in
            if Thread.isMainThread {
                self?.onBell?()
            } else {
                DispatchQueue.main.async { [weak self] in self?.onBell?() }
            }
        }
        emulator.onCommandFinished = { [weak self] duration, exitCode in
            if Thread.isMainThread {
                self?.onCommandFinished?(duration, exitCode)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onCommandFinished?(duration, exitCode) }
            }
        }
        emulator.onNotification = { [weak self] title, body in
            if Thread.isMainThread {
                self?.onDesktopNotification?(title, body)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onDesktopNotification?(title, body) }
            }
        }
        emulator.onPointerShapeChange = { [weak self] shape in
            if Thread.isMainThread {
                self?.applyPointerShape(shape)
            } else {
                DispatchQueue.main.async { [weak self] in self?.applyPointerShape(shape) }
            }
        }
        emulator.onSetClipboard = { [weak self] text in
            guard !text.isEmpty else { return }
            if Thread.isMainThread {
                guard let self, self.allowProgramClipboardAccess else { return }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.onCopy?(text)   // mirror into the daemon paste buffer, like a yank
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.allowProgramClipboardAccess else { return }
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    self.onCopy?(text)   // mirror into the daemon paste buffer, like a yank
                }
            }
        }
        // Answer OSC 10/11/12/4 color queries from the resolved theme (light/dark detection).
        let colorProviderState = colorProviderState
        emulator.colorProvider = { role in
            colorProviderState.resolve(role)
        }
    }

    /// Set the terminal identity the engine answers in XTVERSION (`CSI > q`) and secondary DA
    /// (`CSI > c`). Resolved by the host from the `terminal-identity` option (HarnessCore
    /// `TerminalIdentity`). Mutated on the emulator's serial queue since the replies are produced
    /// while feeding output off-main.
    public func setTerminalIdentity(name: String, version: String, daVersion: Int) {
        emulatorState.sync { emulator in
            emulator.terminalName = name
            emulator.terminalVersion = version
            emulator.secondaryDAVersion = daVersion
        }
    }

    /// Program-requested mouse pointer (OSC 22); nil = system default. Applied via cursor rects.
    private var programPointerCursor: NSCursor?

    private func applyPointerShape(_ shape: String?) {
        programPointerCursor = shape.flatMap(Self.cursor(forShape:))
        window?.invalidateCursorRects(for: self)
    }

    override public func resetCursorRects() {
        if let programPointerCursor {
            addCursorRect(bounds, cursor: programPointerCursor)
        } else {
            super.resetCursorRects()
        }
        // Added last so it wins over the base/program cursor for the link's region: ⌘-hovering
        // a link shows the pointing hand, signalling it's ⌘-clickable.
        if let rect = hoveredLinkRect() {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// Map a CSI/OSC-22 pointer-shape name to an `NSCursor`. Unknown shapes fall back to the
    /// system default (nil) rather than guessing.
    private static func cursor(forShape name: String) -> NSCursor? {
        switch name.lowercased() {
        case "text", "ibeam", "xterm": return .iBeam
        case "pointer", "hand", "pointinghand": return .pointingHand
        case "default", "arrow", "left_ptr": return .arrow
        case "crosshair": return .crosshair
        case "grab", "openhand": return .openHand
        case "grabbing", "closedhand": return .closedHand
        default: return nil
        }
    }

    private func buildRenderer() {
        guard let device = metalLayer.device ?? MTLCreateSystemDefaultDevice() else { return }
        metalLayer.device = device
        let scale = window?.backingScaleFactor ?? 2.0
        renderer = TerminalMetalRenderer(
            device: device,
            fontFamily: fontFamily,
            fontSize: fontSize,
            scale: scale,
            fontThicken: fontThicken,
            fontThickenStrength: fontThickenStrength
        )
        // Tell the engine the real cell pixel size so inline-image cell footprints + cursor
        // advancement match what the renderer draws.
        if let renderer {
            emulatorSync { $0.setCellPixelSize(width: renderer.cellPixelWidth, height: renderer.cellPixelHeight) }
            renderer.textBlinkHidden = textBlinkHidden // a fresh renderer adopts the current phase
        }
        invalidateRenderGeneration()
    }

    // MARK: - Layout & rendering

    // No deinit teardown for the display link: a CADisplayLink strongly retains its target, so the
    // link keeps this view alive until `stopDisplayLink()` calls `invalidate()` (which also nils
    // `renderLink`). deinit therefore only runs once the link is already gone — accessing the
    // main-actor-isolated `renderLink` from a nonisolated deinit would also be a Swift 6 error.
    // `viewDidMoveToWindow(nil)` is the teardown hook (AppKit always calls it before dealloc).

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowKeyObservers.forEach(NotificationCenter.default.removeObserver(_:))
        windowKeyObservers.removeAll()
        if let window {
            StartupMetrics.shared.mark(.firstSurfaceAttached) // idempotent: first surface in a window
            buildRenderer() // pick up the real backing scale
            startDisplayLink()
            updateGridSize()
            scheduleRender()
            // Track the window's key state: focus (hollow cursor, blink, DECSET 1004
            // reports) means "first responder in the key window", not just first responder.
            // Refresh it BEFORE arming the blink timer — the timer only schedules while
            // `effectivelyFocused`, which reads this flag.
            windowIsKey = window.isKeyWindow
            restartBlinkTimer()
            let nc = NotificationCenter.default
            windowKeyObservers.append(nc.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.windowIsKey = true
                    self.focusStateChanged()
                }
            })
            windowKeyObservers.append(nc.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.windowIsKey = false
                    self.focusStateChanged()
                }
            })
            // Track occlusion (covered / minimized / other Space): an invisible pane must not
            // acquire drawables or present — Apple guidance, and it keeps a backgrounded build
            // or `tail -f` from waking the GPU at full cadence. Notification-driven only, NOT
            // seeded from the current state: a window that has never been ordered on screen
            // reads as non-visible (every headless test window, and briefly during launch), and
            // gating those would be wrong — the first real occlusion change corrects any
            // attach-while-covered case.
            windowKeyObservers.append(nc.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.setWindowOccluded(!window.occlusionState.contains(.visible))
                }
            })
            window.makeFirstResponder(self)
            focusStateChanged()
        } else {
            // Removed from the window (pane closed / re-mounted): stop the blink timers so
            // they don't keep the run loop (and a dangling render) alive. The timers hold
            // `[weak self]`, so this is the teardown hook (no retain cycle either way).
            blinkTimer?.invalidate()
            blinkTimer = nil
            textBlinkTimer?.invalidate()
            textBlinkTimer = nil
            textBlinkHidden = false
            renderer?.textBlinkHidden = false
            stopDisplayLink()
            invalidateRenderGeneration()
            // A view can leave the window MID-DRAG (tab close / pane remount during a live
            // resize) and AppKit does not guarantee `viewDidEndLiveResize` then. This instance
            // is cached and re-hosted (`TerminalPaneRegistry`), so unwind the live-resize state
            // here too — a latched `presentsWithTransaction` would route every later present
            // through the synchronous (main-blocking) path outside any resize, and a stale
            // frozen origin would mis-anchor the next layout. The pending commit is cancelled,
            // not flushed: re-attach runs `layout()`, which re-schedules a commit if the size
            // really differs.
            metalLayer.presentsWithTransaction = false
            metalLayer.maximumDrawableCount = 2 // unwind the drag-scoped third drawable too
            liveResizeFrozenOrigin = nil
            resizeCommitWork?.cancel()
            resizeCommitWork = nil
            // Drop any in-flight preview build too (the generation bump above already declines
            // its hop, but a re-attach at the SAME size would not re-bump): clear the target and
            // advance the preview token so a late landing can never stash a stale-width frame
            // into the re-hosted view.
            _ = emulatorState.claimPreviewToken()
            previewCols = 0; previewRows = 0
            // And any staged-but-unapplied resize target: re-attach runs `layout()`, which
            // commits the real size if it differs — a stale mid-drag target applying to the
            // re-hosted view would resize the grid behind that layout's back.
            emulatorState.clearPendingResize()
        }
    }

    /// Drive renders at the display's refresh rate while in a window. The link starts paused;
    /// `scheduleRender` wakes it, and `displayTick` re-pauses it once the screen is up to date, so an
    /// idle terminal costs nothing. macOS 14+ `NSView.displayLink` is the main-thread display source.
    private func startDisplayLink() {
        guard renderLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(displayTick))
        link.isPaused = true
        link.add(to: .current, forMode: .common)
        renderLink = link
        applyPreferredFrameRateRange()
        scheduler.start()
    }

    /// On a variable-refresh (ProMotion) display, ask for the panel's full rate while the link is
    /// awake — the WWDC-recommended range form (min 60 lets the system adapt down for power). A
    /// no-op on fixed 60Hz panels and when the system already drives the link at native rate; the
    /// link only runs while there's pending paint, so this never holds the panel at 120Hz at idle.
    /// Re-applied on backing-property changes (the cross-monitor drag path).
    private func applyPreferredFrameRateRange() {
        guard let link = renderLink,
              let maxFPS = window?.screen?.maximumFramesPerSecond, maxFPS > 60 else { return }
        link.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60, maximum: Float(maxFPS), preferred: Float(maxFPS))
    }

    private func stopDisplayLink() {
        renderLink?.invalidate()
        renderLink = nil
        scheduler.stop()
    }

    /// Window visibility changed (occlusion observer / attach seed). While occluded the scheduler
    /// holds every present — dirty marks and parsing continue, so the pane stays current and
    /// costs no GPU work. On becoming visible, re-arm: any output that arrived while covered
    /// accumulated engine damage, so the next tick builds and presents one up-to-date frame.
    private func setWindowOccluded(_ occluded: Bool) {
        guard occluded != scheduler.isOccluded else { return }
        scheduler.setOccluded(occluded)
        // Blink timers follow visibility (idle efficiency): a covered/minimized pane has
        // nothing to blink — stop the wakeups; re-arm when it can show again.
        restartBlinkTimer()
        updateTextBlinkTimer(frameHasBlink: lastFrameHadBlink)
        if !occluded { scheduleRender() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        buildRenderer()
        applyPreferredFrameRateRange() // the view may have moved to a different-refresh display
        // Backing scale changed (e.g. the drag crossed monitors): a frozen drag origin is in
        // old-scale device pixels — drop it, recompute at the new scale, and re-freeze so the
        // rest of the drag stays anchored.
        let wasFrozen = liveResizeFrozenOrigin != nil
        liveResizeFrozenOrigin = nil
        updateGridSize()
        if wasFrozen, hasSizedGrid { liveResizeFrozenOrigin = (originOffsetX, originOffsetY) }
        scheduleRender()
    }

    /// Glitchless live resize (Hume's technique; Ghostty parity). While the user drags the window
    /// edge, the layer presents *with* the Core Animation transaction: every present becomes
    /// commit → `waitUntilScheduled()` → `drawable.present()` (see the renderer's
    /// `synchronizedWithTransaction`), so the terminal frame and the window's new frame land in
    /// the SAME transaction — content stays latched to the edge instead of lagging it by 1–2
    /// vsyncs (the judder the async present produces). The mode lives exactly as long as the
    /// drag: outside it, the async present path keeps its latency profile.
    /// `allowsNextDrawableTimeout` deliberately stays on (see `configureLayer`): a nil drawable
    /// mid-drag skips one transaction's present and self-heals on the next layout — preferable
    /// to an unbounded main-thread wait if the GPU wedges.
    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        metalLayer.presentsWithTransaction = true
        // Transaction-mode presents hand their drawable to the window server until the CA commit
        // completes, so with the steady-state pool of 2 (kept for keystroke echo latency) the
        // next drag tick parks in `nextDrawable()` for most of a frame (measured p50 ~12ms on
        // 120Hz hardware). A third drawable for the duration of the drag keeps one free while two
        // ride their transactions; the in-flight semaphore stays at 2 — GPU completion is not the
        // bottleneck here (semaphoreWait measured 0), the held presents are.
        metalLayer.maximumDrawableCount = 3
        // Anchor the grid for the whole drag; re-centered once in `viewDidEndLiveResize`.
        // Before the first real layout there's no meaningful origin to freeze — leave nil so
        // `updateGridSize` computes normally.
        liveResizeFrozenOrigin = hasSizedGrid ? (originOffsetX, originOffsetY) : nil
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        metalLayer.presentsWithTransaction = false
        metalLayer.maximumDrawableCount = 2 // restore the low-latency echo pool (see configureLayer)
        // Invalidate any in-flight preview build UNCONDITIONALLY. A live commit's generation bump
        // usually covers this, but a drag that returns to its ORIGINAL size commits nothing (no
        // bump, previewCols still holds the last intermediate target) — a slow build for that
        // intermediate width landing after release would pass every guard and stash a wrong-width
        // frame. Advancing the preview token + clearing the target makes both the on-queue skip and
        // the hop guards drop it.
        _ = emulatorState.claimPreviewToken()
        previewCols = 0; previewRows = 0
        // Unfreeze and recompute geometry/origin for the SETTLED size. With live reflow on this is
        // almost always a pure re-center — the last cell-boundary commit already reflowed + sent
        // the final size; with live reflow off it schedules the drag's one-and-only debounced
        // commit. Either mode, a release landing exactly on a not-yet-processed boundary schedules
        // a fresh commit here, flushed immediately just below.
        liveResizeFrozenOrigin = nil
        updateGridSize()
        // Flush any pending grid+PTY commit NOW: the size is settled the moment the drag ends and
        // transaction mode is off, so it lands immediately instead of waiting out the coalescing
        // delay (which exists only for *animated* resizes — sidebar slides, tiling). `perform` runs
        // it synchronously; `cancel` stops the queued asyncAfter copy from re-running it (and
        // `commitGridSize` is idempotent via its cols/rows guard anyway). Ordered AFTER
        // `updateGridSize` so a commit it just scheduled for a boundary-landing release is caught.
        if let work = resizeCommitWork {
            resizeCommitWork = nil
            work.perform()
            work.cancel()
        }
        if !repaintLastFrame() { scheduleRender() }
    }

    public override func layout() {
        super.layout()
        // Resize the drawable and repaint in the SAME turn, with implicit animations off, so a
        // resize never shows a stale frame stretched to the new bounds (the flicker).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let needsFirstPaint = !hasSizedGrid
        updateGridSize()
        if needsFirstPaint {
            // First real layout: `updateGridSize` already committed the grid; build + present the
            // true frame synchronously so the terminal opens correct with no flash.
            scheduler.forceRender()
        } else if !repaintLastFrame() {
            // Resize/animation storm: re-present the cached frame at the new size — no emulator-queue
            // access, so a window drag never blocks on the output parser (the jank source). Fresh
            // output still lands between layout frames via the async display-link path. Fall back to
            // a full synchronous build only when there's no valid cached frame (e.g. generation just
            // changed via a font/theme/reflow invalidation).
            scheduler.forceRender()
        }
        CATransaction.commit()
    }

    /// Recompute columns/rows from the view size and resize the emulator + drawable.
    private func updateGridSize() {
        guard let renderer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        // Round (not floor) so the drawable exactly covers the layer's pixel area. With
        // `contentsGravity = .topLeft`, a floored (sub-pixel-short) drawable leaves a
        // transparent sliver at the right/bottom edge — a thin seam showing the blur through.
        let pixelWidth = max(1, Int((bounds.width * scale).rounded()))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded()))
        metalLayer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)

        // Inset the grid by the window padding (in device pixels); the same offset is the
        // renderer's draw origin so the padding region shows the canvas color.
        let geometry = Self.computeGridGeometry(
            pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            basePadX: Int((paddingPointsX * scale).rounded()),
            basePadY: Int((paddingPointsY * scale).rounded()),
            cellWidth: renderer.cellPixelWidth, cellHeight: renderer.cellPixelHeight,
            balanced: paddingBalanced,
            // The frozen origin is the live-resize signal (set in viewWillStartLiveResize,
            // cleared in viewDidEndLiveResize / detach) — NOT NSView.inLiveResize, which only
            // AppKit's drag loop sets, so the lifecycle stays directly drivable in tests.
            frozenOrigin: liveResizeFrozenOrigin
        )
        originOffsetX = geometry.originX
        originOffsetY = geometry.originY
        let newCols = geometry.cols
        let newRows = geometry.rows
        guard newCols != columns || newRows != rows else { return }
        if !hasSizedGrid {
            // First real layout: size immediately so the terminal opens correct (no flash).
            hasSizedGrid = true
            commitGridSize(cols: newCols, rows: newRows)
        } else {
            // Live HUD tick: the integer cols/rows only change at cell boundaries (the drawable
            // resizes smoothly every frame), so this fires exactly when the displayed size ticks.
            onGridSizeWillChange?(newCols, newRows, false)
            if liveResizeReflowEnabled, metalLayer.presentsWithTransaction {
                // Real-time live resize (Ghostty parity): commit the authoritative reflow + PTY
                // SIGWINCH at THIS cell boundary so the running program redraws during the drag,
                // not on release. The reflow runs off-main and coalesces latest-wins, so a fast
                // drag stays cheap. The preview below still rides under it for instant feedback.
                requestLiveResizeCommit(cols: newCols, rows: newRows)
            } else {
                // Legacy / animated path (escape-hatch off, or sidebar slide / tiling which never
                // enter live resize): the drawable already resized above (smooth); defer the
                // authoritative history-wide reflow + PTY SIGWINCH until the size settles so the
                // animation can't storm the shell. Each layout reschedules, so the commit fires
                // once after the last frame.
                scheduleResizeCommit(cols: newCols, rows: newRows)
            }
            // Live re-wrap: show the *content re-wrapped* to the new width during the drag instead of
            // the old grid revealed/clipped — `previewViewportReflow` is O(visible) and non-mutating,
            // so it's affordable every cell-boundary tick. Rebuild only when the cell count changes.
            // The build is async on the emulator queue (this tick's layout re-presents the cached
            // frame at the new drawable size; the re-wrap lands on the next main hop), so a
            // boundary tick costs main no more than a sub-cell tick.
            if newCols != previewCols || newRows != previewRows {
                previewCols = newCols
                previewRows = newRows
                updateResizePreview(cols: newCols, rows: newRows)
            }
        }
    }

    /// Pure grid geometry: cols/rows from the usable (padding-inset) area plus the draw origin.
    /// Normal path: the origin is the padding inset, balanced-centered when enabled — the sub-cell
    /// remainder splits onto both sides instead of `.topLeft` gravity parking it all bottom-right;
    /// the odd pixel (integer / 2) stays bottom-right and is invisible. Recomputed even when the
    /// cell count is unchanged so a sub-cell resize re-centers on the next paint.
    /// Live drag (`frozenOrigin` non-nil): hold the drag-start origin — re-centering every
    /// sub-cell layout shifts the text ±1px per pixel of drag (visible shimmer). Clamped so a
    /// shrink can't push the grid past the drawable's right/bottom edge: the origin slides only
    /// enough to keep the last column/row visible — once per cell boundary, not every pixel.
    /// `viewDidEndLiveResize` re-centers once for the settled size. Static + pure so the headless
    /// tests cover centering/freeze/clamp without a Metal renderer.
    nonisolated static func computeGridGeometry(
        pixelWidth: Int, pixelHeight: Int,
        basePadX: Int, basePadY: Int,
        cellWidth: Int, cellHeight: Int,
        balanced: Bool,
        frozenOrigin: (x: Int, y: Int)?
    ) -> (cols: Int, rows: Int, originX: Int, originY: Int) {
        let usableWidth = max(1, pixelWidth - 2 * basePadX)
        let usableHeight = max(1, pixelHeight - 2 * basePadY)
        let cols = max(1, usableWidth / cellWidth)
        let rows = max(1, usableHeight / cellHeight)
        if let frozen = frozenOrigin {
            return (
                cols, rows,
                min(frozen.x, max(0, pixelWidth - cols * cellWidth)),
                min(frozen.y, max(0, pixelHeight - rows * cellHeight))
            )
        }
        var originX = basePadX
        var originY = basePadY
        if balanced {
            originX += (usableWidth - cols * cellWidth) / 2
            originY += (usableHeight - rows * cellHeight) / 2
        }
        return (cols, rows, originX, originY)
    }

    private func scheduleResizeCommit(cols: Int, rows: Int) {
        resizeCommitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitGridSize(cols: cols, rows: rows) }
        resizeCommitWork = work
        // ~60ms outlasts a frame cadence so it lands once the animation/drag stops, while
        // staying snappy enough that a deliberate resize feels immediate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    /// Commit the settled size to the emulator grid (reflow) and the PTY (one SIGWINCH), then
    /// repaint. The authoritative width reflow is O(history) — tens to hundreds of ms at deep
    /// scrollback — so it runs **off the main thread**: the emulator is confined to its serial queue
    /// (so the resize serializes correctly with any in-flight output feed), and the rebuilt frame is
    /// presented on completion. Main never blocks, so a drag-release never drops a frame; the live
    /// preview (or `repaintLastFrame`) already covers the interim until the authoritative frame lands.
    private func commitGridSize(cols: Int, rows newRows: Int) {
        resizeCommitWork = nil
        // Never commit MID-DRAG (a stationary >60ms hold lets the debounce elapse): the commit
        // bumps the generation — dropping the in-flight preview — but its authoritative re-present
        // (`renderNowOffMain`) defers while the layer presents with the transaction, and with the
        // mouse still no further layout runs: the screen would freeze on a stale-generation frame
        // until the next pointer move. Re-arm instead; `viewDidEndLiveResize` clears the mode
        // FIRST and then flushes, so the commit lands exactly once at release.
        if metalLayer.presentsWithTransaction {
            scheduleResizeCommit(cols: cols, rows: newRows)
            return
        }
        guard cols != columns || newRows != rows else { return }
        // A text selection can't survive a reflow — its anchors reference the OLD grid extents, so
        // after a shrink the highlight renders at stale/out-of-grid coordinates and a copy yields
        // blank/garbage rows. Clear it like the real-time path (`requestLiveResizeCommit`) does;
        // this debounced/animated/legacy commit (and `testingResizeGrid`) skipped it. `clearSelection`
        // no-ops when nothing is selected and avoids the `currentSelectionRegion` getter.
        clearSelection()
        columns = cols
        rows = newRows
        invalidateRenderGeneration()              // bump generation; drop stale preview / plain-frame cache
        lastSentPTYSize = (cols, newRows)          // keep the live-resize vote coalescer in sync
        onResize?(cols, newRows)                  // one PTY SIGWINCH (fire-and-forget)
        onGridSizeWillChange?(cols, newRows, true) // settled size for the HUD
        previewCols = 0; previewRows = 0           // force the next drag to rebuild a fresh preview
        if offMainParserFramePipelineEnabled {
            // Off-main pipeline: stage the settled size and let the next build materialize it on
            // the emulator's serial queue (serialized with the output feed) — `setPendingResize`
            // enqueues ahead of the build below, and last-writer-wins overwrites any stale live
            // target still unapplied from the drag. Main never blocks on the O(history) width
            // reflow; the live preview / repaintLastFrame covers the interim. A superseding newer
            // resize drops this build's present via the generation guard, and its own build
            // applies the newest staged size.
            emulatorState.setPendingResize((cols, newRows))
            renderNowOffMain()
        } else {
            // Main-confined pipeline: the emulator lives on the main thread (no serial queue to
            // offload to), so resize + present synchronously — the pre-existing discipline. Going
            // off-main here would be an unsynchronized mutation of the main-confined emulator.
            emulatorSync { $0.resize(cols: cols, rows: newRows) }
            scheduler.forceRender()
        }
    }

    /// Real-time authoritative commit fired at EVERY cell boundary during a live drag (Ghostty
    /// parity) — the counterpart to `commitGridSize`'s debounced drag-end path. It mutates the real
    /// grid (`emulator.resize`) and sends the PTY `SIGWINCH` (`onResize`) live, so interactive
    /// programs — vim/htop/btop/tmux/less, and any alternate-screen TUI the non-mutating preview
    /// cannot serve — reflow and redraw continuously instead of snapping at release.
    ///
    /// Two costs are tamed so a fast drag stays smooth:
    /// - The O(history) width reflow runs OFF-MAIN on the emulator serial queue and is coalesced
    ///   latest-wins via `renderNowOffMain`'s frame token: a drag crossing N columns runs ~1–3
    ///   reflows, not N (superseded targets skip their resize+build entirely).
    /// - The cross-process PTY vote (`onResize` → daemon ioctl → child `SIGWINCH`) fires only when
    ///   the cell count changed from `lastSentPTYSize`, so a within-column drag frame sends nothing.
    ///
    /// The rebuilt frame presents inside an explicit `CATransaction` (`flushTransaction`) so a
    /// completion landing while the mouse is held *still* (no layout pass to ride) still flushes —
    /// see `presentWithinExplicitTransaction`. Called only while `presentsWithTransaction` (a real
    /// drag) and `liveResizeReflowEnabled`; `updateGridSize` gates both. Requires the off-main
    /// pipeline — on the main-confined escape hatch it falls back to the debounced commit below.
    private func requestLiveResizeCommit(cols: Int, rows newRows: Int) {
        // Only on the off-main pipeline: this commit reflows the emulator ON the serial queue, but
        // with the flag off the emulator is main-confined (`receive` feeds it synchronously on
        // main) and the queue hop would mutate it concurrently with a main-thread parse — the same
        // guard `updateResizePreview` and `commitGridSize` already apply. Fall back to the
        // debounced drag-end commit, whose `commitGridSize` resizes via `emulatorSync` on main.
        guard offMainParserFramePipelineEnabled else {
            scheduleResizeCommit(cols: cols, rows: newRows)
            return
        }
        guard cols != columns || newRows != rows else { return }
        columns = cols
        rows = newRows
        // A text selection can't survive a width reflow (the wrapped rows move under its anchors),
        // so clear it like Terminal.app/iTerm rather than render a stale region. Copy mode and find
        // recompute their viewport-relative state per build, so they self-heal across the reflow.
        // `clearSelection` no-ops when nothing is selected (and avoids the `currentSelectionRegion`
        // getter, which can `emulatorSync` for a word selection — a main-thread stall mid-drag).
        clearSelection()
        // DELIBERATELY no `renderGeneration` bump here. A bump would make `layout()`'s
        // `repaintLastFrame` decline (generation mismatch) and fall to the SYNCHRONOUS `forceRender`,
        // whose `state.sync` would block main behind the in-flight O(history) reflow on the emulator
        // queue — the exact stall the off-main pipeline exists to avoid. Instead the builder-reuse
        // cache is cleared ON the queue right after the resize applies (see `applyPendingResize` at
        // the top of `renderNowOffMain`'s build), and the renderer's row cache auto-invalidates on the
        // dimension change. So between this commit and the authoritative frame landing, layout keeps
        // stretching the cached frame (the same near-free sub-cell repaint), and FIFO queue + main
        // ordering guarantees the latest target's reflow is the one that presents last.
        // PTY SIGWINCH, coalesced caller-side to distinct cell counts (the daemon does not dedupe).
        if lastSentPTYSize?.cols != cols || lastSentPTYSize?.rows != newRows {
            lastSentPTYSize = (cols, newRows)
            onResize?(cols, newRows)
        }
        // Clear the preview target so the next `updateResizePreview` (same boundary tick) rebuilds a
        // fresh re-wrap for this width and a stale in-flight preview can't match `previewCols`.
        previewCols = 0; previewRows = 0
        // Stage the reflow target on the queue (whichever build runs next materializes it — see
        // `pendingResize`) and present the result within an explicit CA transaction.
        emulatorState.setPendingResize((cols, newRows))
        renderNowOffMain(flushTransaction: true)
    }

    /// Run `body` (which presents a transaction-synchronized frame) inside an explicit Core
    /// Animation transaction. With `presentsWithTransaction = true` a `drawable.present()` reaches
    /// the glass only when the enclosing transaction commits; during a live drag the only
    /// transactions are AppKit's per-frame `layout()` passes, so an off-main reflow completing while
    /// the pointer is held still would otherwise never flush (a frozen screen until the next pointer
    /// move). Wrapping the present in our own begin/commit flushes it immediately — the same
    /// mechanism `layout()` relies on (`CATransaction` at the resize site), driven from a completion
    /// handler. A no-op shape outside transaction mode (an explicit transaction around a normal
    /// async present is harmless), so the end-of-drag settle can share the path.
    private func presentWithinExplicitTransaction(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Mark the surface dirty and ensure the display link is running to present it. Every code path
    /// that changes what's on screen (PTY output, blink, focus, selection, copy mode, IME, …) funnels
    /// here, so a burst coalesces to one present at the next display tick instead of one async render
    /// per call. Before the view is in a window (no link yet) this is just the dirty mark; the first
    /// `viewDidMoveToWindow`/`commitGridSize` paints via the synchronous force path.
    private func scheduleRender() {
        scheduler.markDirty()
        wakeDisplayLink()
    }

    /// Resume the display link so a pending paint reaches the screen. No-op until the link exists
    /// (created on window attach).
    private func wakeDisplayLink() {
        renderLink?.isPaused = false
    }

    /// Display-cadence tick: present at most one coalesced frame, then pause the link when there's
    /// nothing left to draw so a quiet terminal doesn't wake the CPU every refresh.
    @objc private func displayTick() {
        scheduler.tick()
        if !scheduler.hasPendingWork {
            renderLink?.isPaused = true
            scheduler.linkDidPause() // reopen the immediate-present path for the next arrival
        }
    }

    private func renderNow(forced: Bool = false) {
        // Off-main pipeline first: its entry owns the drag semantics (output presents flow live
        // under real-time reflow, within explicit CA transactions; the reflow-off escape hatch
        // defers there). Ordering matters — the main-confined hold below must not swallow the
        // scheduler's off-main ticks, or mid-drag output would gate on BOTH pipelines.
        if offMainParserFramePipelineEnabled {
            renderNowOffMain()
            return
        }
        // Main-confined escape hatch: single present source during a live drag. This legacy
        // pipeline has no live commits (requestLiveResizeCommit falls back to the debounce) and
        // a build here runs ON main — an ad-hoc output/tick present would pay the synchronized
        // commit→waitUntilScheduled stall AND replace `lastPresentedResult` with a fresh frame
        // the renderer cache hasn't seen, forcing the next layout repaint back onto the
        // full-rebuild path (defeating the empty-damage reuse that makes drag ticks near-free).
        // Defer instead: re-mark dirty so the work is never lost (`presentNow`/`tick` cleared the
        // flag before calling here); `layout()`'s repaint carries the visual per drag step, and
        // the first tick after `viewDidEndLiveResize` flushes the freshest frame. `forced` keeps
        // the synchronous path (first paint / no-cached-frame fallback inside layout) open.
        if !forced, metalLayer.presentsWithTransaction {
            scheduler.markDirty()
            return
        }
        guard let renderer else { return }
        guard let drawable = metalLayer.nextDrawable() else { scheduler.markDirty(); return }
        let emulator = emulatorState.emulator
        // Copy mode owns the whole surface while active (its own scroll offset + overlay).
        if renderCopyMode(renderer: renderer, drawable: drawable) { lastPlainFrame = nil; return }
        let grid = scrollOffset > 0 ? emulator.readGrid(scrollbackOffset: scrollOffset) : emulator.readGrid()
        // Consume dirty-row damage every frame to keep the engine's "since last render" window
        // aligned, then feed it to the builder only on the plain live path. Scrollback, an active
        // selection, and IME preedit all rebuild every row (they aren't tracked by damage), so
        // they take the full path and reset the reuse cache.
        let damage = emulator.consumeDamage()
        let findHits = findActive
            ? Self.viewportFindHighlights(findMatches, scrollOffset: scrollOffset, historyCount: emulator.historyCount, rows: rows)
            : []
        let selectionRegion = currentSelectionRegion
        let plain = scrollOffset == 0 && selectionRegion == nil && markedText.isEmpty && findHits.isEmpty
        // DECSCNM: a flip arrives with full-screen damage (the engine dirties on real change),
        // so the swapped build repaints everything and the plain-frame cache rebuilds.
        let reverseVideo = emulator.modes.reverseVideo
        let builder = reverseVideo ? frameBuildConfiguration.makeBuilder(reverseVideo: true) : frameBuilder
        let frameBuildStart = DispatchTime.now().uptimeNanoseconds
        var frame: TerminalFrame
        if plain {
            frame = builder.build(grid, region: nil,
                                  imageProvider: { emulator.image(for: $0) },
                                  reusing: lastPlainFrame, damage: damage)
        } else {
            frame = builder.build(grid, region: selectionRegion,
                                  searchHighlights: findHits,
                                  imageProvider: { emulator.image(for: $0) })
        }
        let frameBuildNanos = DispatchTime.now().uptimeNanoseconds &- frameBuildStart
        // IME preedit: draw the in-progress composition over the grid at the cursor.
        if !markedText.isEmpty, scrollOffset == 0 {
            overlayPreedit(into: &frame)
        }
        // DECSCUSR: a program-requested cursor shape (vim/nvim/fish per-mode) overrides the
        // user's `cursorStyle` setting; `.default` keeps the setting.
        switch grid.cursor.shape {
        case .block: frame.cursor.style = .block
        case .bar: frame.cursor.style = .bar
        case .underline: frame.cursor.style = .underline
        case .default: break
        }
        // Cursor blink: hide on the off-beat (only while focused + blink enabled). The program's
        // DECSCUSR blink preference overrides the setting; a program-hidden cursor stays hidden.
        let blinkEnabled = grid.cursor.blinking ?? cursorBlinkEnabled
        if frame.cursor.visible, focused, blinkEnabled, !cursorBlinkVisible {
            frame.cursor.visible = false
        }
        // Unfocused → hollow cursor (outline block / dimmed bar-underline), never blinking.
        frame.cursor.hollow = !effectivelyFocused
        // Clear to the canvas color at canvas opacity so any cell-rounding remainder reads
        // as the canvas (no seam, and translucent when opacity < 1). The grid draws at the
        // padding origin so the inset region shows the canvas.
        let didPresent = renderer.present(
            frame,
            to: drawable,
            clearColor: builder.renderColor(reverseVideo ? canvasForeground : canvasBackground, alpha: canvasOpacity),
            origin: (originOffsetX, originOffsetY),
            gamma: glyphGamma,
            ligatures: ligaturesEnabled,
            damage: plain ? damage : nil,
            frameBuildNanos: frameBuildNanos,
            synchronizedWithTransaction: metalLayer.presentsWithTransaction
        )
        if didPresent {
            onRenderStats?(renderer.stats)
            updateTextBlinkTimer(frameHasBlink: frame.hasBlink)
        } else { scheduleRender() } // transient encode/present failure — retry next tick
        StartupMetrics.shared.mark(.firstDrawablePresented) // idempotent: only the first present counts
        // Retain only a plain frame for row reuse; a selection/scrollback/preedit frame would
        // poison the cache with overlay-baked cells, so drop it. (`plain` already excludes IME.)
        lastPlainFrame = plain ? frame : nil
    }

    /// Force path (resize / first-paint / 2026-timeout): present in the SAME runloop turn so the
    /// frame is on screen before the caller's `CATransaction` commits. The on-main pipeline already
    /// renders synchronously; the off-main pipeline must build-and-present inline rather than via its
    /// normal async hop (which would flash a stale grid stretched to the new bounds).
    private func renderNowSynchronous() {
        if offMainParserFramePipelineEnabled {
            renderNowOffMain(synchronous: true)
        } else {
            renderNow(forced: true)
        }
    }

    private func renderNowOffMain(
        synchronous: Bool = false,
        flushTransaction: Bool = false
    ) {
        // Live-drag hold for the scheduler's async entry — ESCAPE HATCH ONLY. With real-time
        // reflow off, the drag's contract is defer-to-release: the grid stays at its pre-drag
        // size while the re-wrap PREVIEW (a different cell count) owns the glass, so an output
        // build presenting the old-size grid mid-drag would visibly fight the preview's frame.
        // With real-time reflow ON (the default), boundary commits keep the real grid current,
        // so output builds present the same size the drag shows — they flow live (each present
        // flushes its own explicit CATransaction below), which is what keeps streaming output,
        // SIGWINCH redraws, and keystroke echo moving DURING the drag instead of one boundary
        // behind. The synchronous (layout/forceRender) entry always presents — it is a drag
        // present source; a live-resize commit (`flushTransaction`) likewise.
        if !synchronous, !flushTransaction, metalLayer.presentsWithTransaction, !liveResizeReflowEnabled {
            scheduler.markDirty()
            return
        }
        guard renderer != nil else { return }
        let generation = renderGeneration
        let state = emulatorState
        let config = frameBuildConfiguration
        let requestedScrollOffset = scrollOffset
        // Capture the RAW selection here (cheap, no emulator access) and resolve it on the emulator
        // queue inside the build — see `resolveSelectionRegion`. Resolving on main would `emulatorSync`
        // for a word selection and stall main behind the in-flight feed every build.
        let rawSelection = currentRawSelection
        let preedit = markedText
        let blinkSetting = cursorBlinkEnabled
        let blinkVisible = cursorBlinkVisible
        let isFocused = effectivelyFocused
        let copyModeState = copyMode
        let searchEntry = copyModeSearchEntry
        let viewRows = rows
        let viewColumns = columns
        let fg = canvasForeground
        let bg = canvasBackground
        let opacity = canvasOpacity
        let findIsActive = findActive
        let findMatchesSnapshot = findMatches

        // The frame build, identical for the async (coalesced) and synchronous (forced) paths. Pure
        // over the captured value snapshot + the emulator; the only mutation is `state`'s plain-frame
        // cache, which is always touched on the serial queue (sync runs there; async dispatches there).
        let build: @Sendable (TerminalEmulator) -> SurfaceFrameBuildResult = { emulator in
            // Materialize any staged resize on the queue right before the build so it serializes
            // with the in-flight output feed. EVERY output/commit build applies the shared target
            // (`pendingResize`): a superseded commit build (its token is no longer latest) returns
            // before this runs, and whichever build superseded it applies the staged size instead —
            // a fast drag reflows only to the latest target (intermediate column counts are never
            // materialized) and the emulator can never strand at a pre-vote size. Clearing the
            // builder-reuse caches here (on the queue, not via a main-thread generation bump) keeps
            // this build from diffing the new grid against an old-width cached frame; the renderer's
            // row cache auto-invalidates on the dimension change.
            if state.applyPendingResize() {
                state.lastPlainFrame = nil
                state.lastViewportFrame = nil
                state.lastOverlayKeys = [:]
            }
            // DECSCNM: read on the emulator's queue (serialized with the feed that set it);
            // a flip arrives with full-screen damage, so the swap repaints everything.
            let reverseVideo = emulator.modes.reverseVideo
            let builder = config.makeBuilder(reverseVideo: reverseVideo)
            let frameBuildStart = DispatchTime.now().uptimeNanoseconds
            var frame: TerminalFrame
            var renderDamage: TerminalDamage?
            var scrollShift = 0
            var peekRow = false
            if let cm = copyModeState {
                let offset = cm.scrollbackOffset(historyCount: emulator.historyCount)
                let grid = emulator.readGrid(scrollbackOffset: offset)
                let region: SelectionRegion? = cm.viewportSelection(rows: viewRows, columns: viewColumns).map { vs in
                    switch vs.kind {
                    case .linear:
                        return .linear(TerminalSelection((vs.startRow, vs.startColumn), (vs.endRow, vs.endColumn)))
                    case .block:
                        return .block(BlockSelection((vs.startRow, vs.startColumn), (vs.endRow, vs.endColumn)))
                    }
                }
                let hits = cm.viewportSearchHits(rows: viewRows).map { m in
                    TerminalSelection((m.line, m.startColumn), (m.line, max(m.startColumn, m.endColumn - 1)))
                }
                frame = builder.build(grid, region: region, searchHighlights: hits,
                                      copyModeCursor: cm.viewportCursor(rows: viewRows),
                                      imageProvider: { emulator.image(for: $0) })
                let statusText = searchEntry.map { (cm.search.reverse ? "?" : "/") + $0 } ?? cm.statusLine()
                Self.applyCopyModeStatus(into: &frame, text: statusText, builder: builder,
                                         selectionBackground: config.selectionBackground,
                                         canvasForeground: fg, canvasBackground: bg)
                state.lastPlainFrame = nil
                state.lastViewportFrame = nil // copy-mode frames bake overlays — not a shift source
            } else {
                // Scrolled views build with the smooth-scroll peek row appended (rows+1 tall) so
                // the fraction translate always has real content to reveal; the live view (offset
                // 0) stays byte-identical. Augmenting whenever scrolled — not just when a fraction
                // is active — keeps the frame shape uniform across the whole scrolled regime, so
                // `buildShifted` keeps rotating instead of bailing on a rows mismatch.
                peekRow = requestedScrollOffset > 0
                // `gridRead` brackets boundary 1 (the engine→renderer grid snapshot) on the
                // signpost track, so a per-boundary trace can attribute build time to the
                // snapshot copy vs the RenderCell resolve that follows.
                let (grid, damage) = FrameSignposter.shared.interval("gridRead") {
                    () -> (TerminalGridSnapshot, TerminalDamage) in
                    let grid = peekRow
                        ? Self.appendingPeekRow(
                            to: emulator.readGrid(scrollbackOffset: requestedScrollOffset),
                            emulator: emulator, offset: requestedScrollOffset
                        )
                        : emulator.readGrid()
                    return (grid, emulator.consumeDamage())
                }
                let findHits = findIsActive
                    ? Self.viewportFindHighlights(findMatchesSnapshot, scrollOffset: requestedScrollOffset, historyCount: emulator.historyCount, rows: viewRows)
                    : []
                // Resolve the selection HERE, on the emulator queue: a `.word` selection reads
                // `wordColumnRange` directly (free) instead of stalling main via `emulatorSync`, and
                // it resolves against the same emulator state this frame renders.
                let selectionRegion = Self.resolveSelectionRegion(rawSelection, emulator: emulator,
                                                                  scrollOffset: requestedScrollOffset,
                                                                  columns: viewColumns)
                let overlayFree = selectionRegion == nil && preedit.isEmpty && findHits.isEmpty
                // The LIVE view (offset 0) always builds CLEAN: selection/find/preedit are
                // re-shaded onto a copy after the reuse caches are updated (the cell-overlay
                // pass below), so they ride damage-driven incremental builds instead of forcing
                // a full rebuild every frame for their whole duration. Scrolled views keep the
                // baked full-rebuild path (overlay coordinates while scrolled are rarer and not
                // worth the extra path).
                let plain = requestedScrollOffset == 0
                // Scroll-delta fast path: a pure scrollback scroll (the offset changed, nothing
                // else did — no output since the last overlay-free frame, no overlays now) is the
                // previous frame shifted by the offset delta. `buildShifted` re-resolves only the
                // newly-exposed rows; `scrollShift` + the exposed-row damage let the renderer
                // rotate its row cache the same way. This covers k→k′ scrolls AND the 0→k / k→0
                // transitions (landing at 0 yields a byte-identical plain frame, so the plain
                // cache below stays coherent). `damage.rows.isEmpty` is the no-output guard —
                // cursor moves list their rows there, so they conservatively take the full path.
                let scrollDelta = requestedScrollOffset - state.lastViewportOffset
                if overlayFree, scrollDelta != 0,
                   damage.rows.isEmpty, !damage.full,
                   state.lastViewportGeneration == generation,
                   let previous = state.lastViewportFrame,
                   let shifted = builder.buildShifted(grid, reusing: previous, shift: scrollDelta) {
                    frame = shifted
                    scrollShift = scrollDelta
                    // Exposed band in FRAME rows (grid.rows == viewRows + 1 when the peek row is
                    // appended): a shift toward live exposes the bottom band including the peek.
                    let exposed = scrollDelta > 0
                        ? IndexSet(integersIn: 0 ..< min(scrollDelta, grid.rows))
                        : IndexSet(integersIn: max(0, grid.rows + scrollDelta) ..< grid.rows)
                    renderDamage = TerminalDamage(rows: exposed)
                } else if plain {
                    // Only reuse a cached frame built for THIS generation — a stale-generation frame
                    // describes the old grid and would tear when diffed against fresh damage.
                    let reuse = state.lastPlainFrameGeneration == generation ? state.lastPlainFrame : nil
                    let fresh = damage.rows.subtracting(damage.scrolledRows)
                    // Output-scroll fast path: the engine reported a whole-viewport scroll
                    // (`damage.scroll`), so the moved band shift-copies from the previous frame
                    // and only the fresh rows (writes, blank band, cursor rows) re-resolve.
                    // `scrollShift` lets the renderer rotate its row-instance cache the same way
                    // it does for scrollback scrolls; the fresh band is its re-encode set. Any
                    // bail (no reusable frame, images, geometry) falls back to the plain build,
                    // whose `damage.rows` still covers the whole moved band.
                    if damage.scroll != 0, !damage.full, !damage.scrolledRows.isEmpty,
                       let prev = reuse,
                       let shifted = builder.buildShifted(grid, reusing: prev,
                                                          shift: damage.scroll, freshRows: fresh) {
                        frame = shifted
                        scrollShift = damage.scroll
                        renderDamage = TerminalDamage(rows: fresh)
                    } else {
                        frame = builder.build(grid, region: nil,
                                              imageProvider: { emulator.image(for: $0) },
                                              reusing: reuse, damage: damage)
                        renderDamage = damage
                    }
                } else {
                    frame = builder.build(grid, region: selectionRegion,
                                          searchHighlights: findHits,
                                          imageProvider: { emulator.image(for: $0) })
                    // Overlay-free full rebuilds (scrolled views) present with FULL damage, not
                    // nil: the instances are identical, but the encode routes through the
                    // cache-populating path, so the row cache is warm for the next scroll
                    // rotation or fraction-only repaint (nil would reset it and force the next
                    // tick to re-encode everything). Overlay frames keep nil — their baked
                    // highlight cells must not poison the cache.
                    if overlayFree {
                        renderDamage = TerminalDamage(full: true)
                    }
                }
                switch grid.cursor.shape {
                case .block: frame.cursor.style = .block
                case .bar: frame.cursor.style = .bar
                case .underline: frame.cursor.style = .underline
                case .default: break
                }
                let blinkEnabled = grid.cursor.blinking ?? blinkSetting
                if frame.cursor.visible, isFocused, blinkEnabled, !blinkVisible {
                    frame.cursor.visible = false
                }
                frame.cursor.hollow = !isFocused // unfocused → hollow outline / dimmed cursor
                // Caches hold the CLEAN frame: on the live path the overlay pass below shades a
                // copy, so reuse stays warm through a selection drag / find session / composition.
                state.lastPlainFrame = plain ? frame : nil
                state.lastPlainFrameGeneration = generation
                // Refresh the scroll-reuse source: any clean, image-free viewport frame qualifies
                // (the live view always builds clean now; a scrolled view only when overlay-free —
                // scrolled overlay frames bake highlight colors into cells, so they poison it).
                if plain || overlayFree, frame.images.isEmpty {
                    state.lastViewportFrame = frame
                    state.lastViewportOffset = requestedScrollOffset
                    state.lastViewportGeneration = generation
                } else {
                    state.lastViewportFrame = nil
                }
                // Cell-overlay pass (live view only): re-shade the selection / find rows of a
                // copy and lay the IME preedit over it, leaving the cached clean frame above
                // untouched. The render damage gains exactly the rows whose overlay fingerprint
                // changed since the last build, so a selection drag re-encodes the rows it
                // crossed — a static highlight (or an idle find bar) adds nothing per frame.
                if plain {
                    let keys = Self.overlayRowKeys(
                        selection: selectionRegion, findHits: findHits, preedit: preedit,
                        preeditCursor: (frame.cursor.row, frame.cursor.column),
                        rows: grid.rows, cols: grid.cols
                    )
                    if !keys.isEmpty {
                        builder.applyHighlights(into: &frame, from: grid, region: selectionRegion,
                                                searchHighlights: findHits, rows: IndexSet(keys.keys))
                        if !preedit.isEmpty {
                            Self.applyPreedit(into: &frame, text: preedit, builder: builder,
                                              canvasForeground: fg, canvasBackground: bg)
                        }
                    }
                    if var damage = renderDamage, !damage.full {
                        for (row, key) in keys where state.lastOverlayKeys[row] != key {
                            damage.rows.insert(row)
                        }
                        for row in state.lastOverlayKeys.keys where keys[row] == nil {
                            damage.rows.insert(row)
                        }
                        if !keys.isEmpty || !state.lastOverlayKeys.isEmpty { damage.cursorOnly = false }
                        renderDamage = damage
                    }
                    state.lastOverlayKeys = keys
                }
            }
            return SurfaceFrameBuildResult(
                generation: generation,
                frame: frame,
                damage: renderDamage,
                scrollShift: scrollShift,
                hasPeekRow: peekRow,
                frameBuildNanos: DispatchTime.now().uptimeNanoseconds &- frameBuildStart,
                clearColor: builder.renderColor(reverseVideo ? fg : bg, alpha: opacity)
            )
        }

        if synchronous {
            // Block until the worker builds this frame, then present inline (we're on main inside the
            // caller's CATransaction). `state.sync` queues behind any in-flight build, preserving order.
            let result = state.sync { emulator in
                FrameSignposter.shared.interval("frameBuild") { build(emulator) }
            }
            presentBuiltFrame(result)
        } else {
            let token = state.claimFrameToken()
            let flush = flushTransaction
            state.async { emulator in
                // Latest-wins coalescing: if a newer build is already queued behind this one, skip —
                // it will consume the damage this one would have (no rows lost), so a burst of marks
                // collapses to a single build instead of N stale frames. For a live-resize commit
                // the skip also drops this target's `emulator.resize`, bounding O(history) reflows.
                guard state.isLatestFrameToken(token) else { return }
                let result = FrameSignposter.shared.interval("frameBuild") { build(emulator) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // Any present landing while the layer is in transaction mode flushes its own
                    // explicit CATransaction: a live-resize commit by contract, and an un-gated
                    // mid-drag output build because the mouse may be held still (no layout pass
                    // to carry a transaction-mode present to the glass). Checked at LANDING time —
                    // a build that outlives the drag presents normally (the wrap is a harmless
                    // no-op shape either way, see `presentWithinExplicitTransaction`).
                    if flush || self.metalLayer.presentsWithTransaction {
                        self.presentWithinExplicitTransaction { self.presentBuiltFrame(result) }
                    } else {
                        self.presentBuiltFrame(result)
                    }
                }
            }
        }
    }

    /// Present an already-built off-main frame (main thread). A stale generation / no window / no
    /// renderer is an intentional drop; a nil drawable or a failed present is transient, so re-arm the
    /// scheduler (and wake the link) to retry on the next tick rather than leaving a frame unshown.
    private func presentBuiltFrame(_ result: SurfaceFrameBuildResult) {
        guard renderGeneration == result.generation, window != nil, let renderer else { return }
        let outcome = presentFrame(result, damage: result.damage, scrollShift: result.scrollShift)
        if outcome == .presented {
            // Remember the presented frame so a live resize can re-stretch it without rebuilding
            // (and without touching the emulator queue). See `repaintLastFrame`.
            lastPresentedResult = result
            // The renderer reports whether the encode left its row cache holding exactly this
            // frame's rows — false for the cache-bypassing paths (nil damage) AND for a
            // mid-encode atlas reset that wiped the cache (which a damage-only heuristic here
            // could not distinguish from a normal full encode).
            lastPresentedResultIsRendererCoherent = renderer.stats.rowCacheCoherent
            onRenderStats?(renderer.stats)
            updateTextBlinkTimer(frameHasBlink: result.frame.hasBlink)
        } else {
            // A genuine drop: nothing reached the glass this turn (repaintLastFrame failures
            // don't count — their callers fall back to another present in the same turn).
            // The worker has already diffed this frame's damage away (lastPlainFrame /
            // lastViewportFrame advanced at build time), so the NEXT build can legitimately say
            // "nothing changed" — but the renderer's row cache never received this frame's rows
            // (nil drawable drops before encode) or holds rows the screen never showed (encode
            // failed after mutating them). Either way the cache and the next frame's damage
            // disagree about what's on the glass, so drop the cache: the retry re-encodes fully.
            renderer.invalidateRowReuseCache()
            lastPresentedResultIsRendererCoherent = false
            FrameSignposter.shared.recordFrameDrop(
                outcome == .nilDrawable ? .nilDrawable : .encodeFailure)
            scheduleRender() // transient encode/present failure — retry next tick
        }
        StartupMetrics.shared.mark(.firstDrawablePresented)
    }

    /// Acquire a drawable and present `result`'s frame at the current origin — the one place the
    /// main thread meets the GPU (drawable wait + in-flight semaphore + encode). While the layer is
    /// in `presentsWithTransaction` mode (live resize) the present is routed through the renderer's
    /// transaction-synchronized path, keyed off the layer property itself so present modes can
    /// never mix while the mode is on — DELIBERATE for output/tick presents mid-drag too: an async
    /// `commandBuffer.present` against a transaction-mode layer presents at an indeterminate later
    /// commit (the glitch class this change eliminates), and the uniform sync cost is the bounded
    /// schedule wait (sub-ms, measured as `presentScheduleNanos`), paid only while dragging.
    /// The `present` signpost interval brackets nextDrawable() + the renderer's
    /// inFlightSemaphore.wait(): the drawable / GPU back-pressure (vsync) stall on the main thread
    /// — the term the latency work targets (0b showed parse+build is ~16µs, so any felt lag lives
    /// here, not upstream). When signposts are enabled we also record a rolling p50/p95 breakdown
    /// (total / drawable wait / semaphore wait / schedule). A `false` return is a skipped present
    /// (nil drawable or encode failure) — callers decide whether to retry or fall back; only
    /// `presentBuiltFrame` counts a genuine drop (`recordFrameDrop`), keyed by which failure it was.
    private enum PresentAttempt { case presented, nilDrawable, encodeFailure }

    private func presentFrame(
        _ result: SurfaceFrameBuildResult, damage: TerminalDamage?, scrollShift: Int = 0
    ) -> PresentAttempt {
        guard let renderer else { return .encodeFailure }
        // Smooth scroll is applied at present time from the CURRENT fraction (render-only state):
        // a fraction-only tick re-presents the same frame with just a new uniform. Rounded to
        // whole device pixels so glyphs stay crisp mid-scroll (no sub-pixel resampling).
        // The translate is gated on the FRAME, not just the fraction: (1) a frame without the
        // peek row (built at offset 0 — e.g. the cached live frame re-presented while the first
        // scrolled build is still in flight) must present untranslated, or the translate would
        // open a background gap at the bottom with no row to fill it — the worst case is one
        // un-smooth frame, never a hole; (2) image-bearing frames present untranslated too
        // (`image_vertex` has no scrollPx), so an image scrolling INTO a fractional viewport
        // can never sit misaligned against its text — `scrollByContinuous` quantizes the next
        // position the same way. The clip rides the peek row itself: hidden at fraction 0, and
        // rows slide out of the fixed grid box mid-fraction.
        let canTranslate = result.hasPeekRow && result.frame.images.isEmpty
        let fractionPx = canTranslate && scrollFraction > 0
            ? Float((scrollFraction * CGFloat(renderer.cellPixelHeight)).rounded())
            : 0
        let clipRows = result.hasPeekRow ? result.frame.rows - 1 : nil
        let sp = FrameSignposter.shared
        let presentStart = sp.enabled ? DispatchTime.now().uptimeNanoseconds : 0
        var drawableWaitNanos: UInt64 = 0
        let outcome = sp.interval("present") { () -> PresentAttempt in
            let drawableStart = sp.enabled ? DispatchTime.now().uptimeNanoseconds : 0
            guard let drawable = sp.interval("drawableWait", { metalLayer.nextDrawable() })
            else { return .nilDrawable }
            if sp.enabled { drawableWaitNanos = DispatchTime.now().uptimeNanoseconds &- drawableStart }
            let presented = renderer.present(
                result.frame,
                to: drawable,
                clearColor: result.clearColor,
                origin: (originOffsetX, originOffsetY),
                gamma: glyphGamma,
                ligatures: ligaturesEnabled,
                damage: damage,
                scrollShift: scrollShift,
                scrollFractionPx: fractionPx,
                smoothScrollClipRows: clipRows,
                frameBuildNanos: result.frameBuildNanos,
                synchronizedWithTransaction: metalLayer.presentsWithTransaction
            )
            return presented ? .presented : .encodeFailure
        }
        if sp.enabled, outcome == .presented {
            sp.recordPresent(
                nanos: DispatchTime.now().uptimeNanoseconds &- presentStart,
                drawableWait: drawableWaitNanos,
                semaphoreWait: renderer.stats.semaphoreWaitNanos,
                schedule: renderer.stats.presentScheduleNanos,
                instanceBuild: renderer.stats.buildInstancesNanos,
                upload: renderer.stats.uploadNanos
            )
        }
        return outcome
    }

    /// Append the buffer line just below the scrolled viewport as a display-only (rows+1)th row —
    /// the smooth-scroll peek row the fraction translate reveals. The snapshot stays a uniform
    /// window over `[history ++ viewport]`, so `buildShifted` rotates it like any other row.
    /// `offset ≥ 1` guarantees the line below the viewport exists (it is at worst the live bottom
    /// row); a defensive blank-pad covers width races during reflow. Runs on the emulator queue
    /// (called from the build closure).
    private nonisolated static func appendingPeekRow(
        to snapshot: TerminalGridSnapshot, emulator: TerminalEmulator, offset: Int
    ) -> TerminalGridSnapshot {
        let peekIndex = emulator.historyCount - offset + snapshot.rows
        var line = peekIndex >= 0 && peekIndex < emulator.bufferLineCount
            ? emulator.bufferLine(peekIndex) : []
        if line.count < snapshot.cols {
            line.append(contentsOf: Array(repeating: .blank, count: snapshot.cols - line.count))
        } else if line.count > snapshot.cols {
            line.removeLast(line.count - snapshot.cols)
        }
        return TerminalGridSnapshot(
            cols: snapshot.cols, rows: snapshot.rows + 1, cells: snapshot.cells + line,
            cursor: snapshot.cursor, images: snapshot.images, marks: snapshot.marks
        )
    }

    /// Re-present the last built frame at the *current* drawable size with no emulator-queue access
    /// — the smooth-resize fast path. Used by `layout()` during a live drag/animation: the grid
    /// hasn't reflowed yet (deferred to drag-end), so the cached frame is still the correct content;
    /// we just need to redraw it into the freshly-resized drawable. Returns false when there's no
    /// valid cached frame for this generation, so the caller falls back to a full synchronous build.
    ///
    /// Damage selection is the per-tick cost lever. Under the drag-frozen origin every row-cache
    /// key (cols/rows/origin/atlas) is stable, so when the cache verifiably holds this exact
    /// frame's rows (`lastPresentedResultIsRendererCoherent`) an EMPTY damage reuses every row —
    /// `encodedRows == 0`, zero-copy instance bind, only the viewport uniform changes. When it
    /// doesn't (preview reflow replaced the frame, a drop wiped the cache), a `full` damage pays
    /// one rebuild *through the cache-populating path* so the very next tick is free again —
    /// unlike `damage: nil`, which rebuilds AND leaves the cache empty, making every sub-cell drag
    /// tick a full re-encode (the pre-#57 resize-lag source). Image frames take the same two
    /// paths — image quads draw outside the cell instance buffers, so they never gate reuse.
    @discardableResult
    private func repaintLastFrame() -> Bool {
        guard let result = lastPresentedResult,
              result.generation == renderGeneration,
              window != nil, let renderer else { return false }
        let damage: TerminalDamage?
        if lastPresentedResultIsRendererCoherent {
            damage = TerminalDamage(rows: [], full: false)
        } else {
            damage = TerminalDamage(full: true)
        }
        let didPresent = presentFrame(result, damage: damage) == .presented
        if didPresent {
            lastPresentedResultIsRendererCoherent = renderer.stats.rowCacheCoherent
            onRenderStats?(renderer.stats)
        }
        return didPresent
    }

    /// Build a live re-wrap preview of the viewport at the current drag target `nc × nr` and present
    /// it, so the drag shows the content *re-wrapped to the new width* rather than the old grid
    /// revealed/clipped. Pure: reads the emulator via `previewViewportReflow` (O(visible),
    /// non-mutating) and never reflows history or sends `SIGWINCH` (both deferred to
    /// `commitGridSize`), so the shell's width belief never desyncs from the display. Skipped when an
    /// overlay the preview can't represent is active (scrollback, selection, IME pre-edit, find, copy
    /// mode) or on the alternate screen — `repaintLastFrame` then keeps re-presenting the cached frame.
    ///
    /// The build runs **async on the emulator queue** (latest-wins token, the `renderNowOffMain`
    /// coalescing pattern): a boundary-crossing tick never parks main on the queue — not behind an
    /// in-flight parse under heavy output (the old `pendingFeed.isBusy` skip dodged that but still
    /// paid the full build wall when idle), and not even for the build itself. While the build is in
    /// flight, `layout()` keeps re-presenting the last cached frame at the new drawable size, so the
    /// drag never drops a frame; the re-wrapped content lands on the next main hop via
    /// `presentResizePreview`. A fast drag's boundary builds coalesce to the freshest `nc × nr`.
    ///
    /// DELIBERATE TRADE: the boundary tick shows ≤1 frame of the previous column count's wrap at
    /// the new drawable size before the re-wrap lands (the old synchronous code showed the re-wrap
    /// same-tick but stalled main for the reflow+build — a blown frame budget on big grids, and it
    /// SKIPPED the re-wrap entirely under parser load). Frame pacing wins over single-frame wrap
    /// fidelity; under load the async path is strictly better (stale wrap either way, no stall).
    private func updateResizePreview(cols nc: Int, rows nr: Int) {
        // Only on the off-main pipeline (the emulator lives on its serial queue; when the flag is
        // off it is main-confined and the async hop below would touch it off its confinement domain).
        guard offMainParserFramePipelineEnabled else { return }
        guard scrollOffset == 0, copyMode == nil, selectionAnchor == nil,
              markedText.isEmpty, !findActive else { return }
        let config = frameBuildConfiguration
        let bg = canvasBackground
        let fg = canvasForeground
        let opacity = canvasOpacity
        let isFocused = effectivelyFocused
        let generation = renderGeneration
        let state = emulatorState
        // Preview-namespace token (NOT claimFrameToken): the output pipeline must not cancel an
        // in-flight re-wrap — during an animated resize both pipelines run concurrently.
        let token = state.claimPreviewToken()
        state.async { emulator in
            // Latest-wins within the preview pipeline: a further boundary tick is already queued
            // behind this one — skip; it renders a strictly newer drag target.
            guard state.isLatestPreviewToken(token) else { return }
            guard let preview = emulator.previewViewportReflow(cols: nc, rows: nr) else { return }
            let buildStart = DispatchTime.now().uptimeNanoseconds
            let reverseVideo = emulator.modes.reverseVideo
            let builder = config.makeBuilder(reverseVideo: reverseVideo)
            var frame = FrameSignposter.shared.interval("frameBuild") {
                builder.build(preview, region: nil, imageProvider: { emulator.image(for: $0) })
            }
            frame.cursor.hollow = !isFocused
            // NOTE: must not touch `state.lastPlainFrame`/`lastViewportFrame` — the preview has
            // different dims than the live grid and would poison the damage-reuse caches.
            let result = SurfaceFrameBuildResult(
                generation: generation, frame: frame, damage: nil,
                frameBuildNanos: DispatchTime.now().uptimeNanoseconds &- buildStart,
                clearColor: builder.renderColor(reverseVideo ? fg : bg, alpha: opacity)
            )
            DispatchQueue.main.async { [weak self] in
                self?.presentResizePreview(result, cols: nc, rows: nr, token: token)
            }
        }
    }

    /// Main-hop landing for an async preview build. Drops a stale preview outright rather than
    /// stashing it: an async build can land after the drag moved to a different cell target, or
    /// after the settled commit bumped the generation — stashing a frame for the wrong grid would
    /// re-present mis-wrapped content on every subsequent sub-cell repaint. A current preview is
    /// stashed exactly like the old synchronous path (coherence broken: the renderer cache still
    /// holds the previous frame's rows) and repainted immediately — the repaint pays the one
    /// cache-populating full rebuild per geometry change, and the tick after it is free again.
    /// Returns whether the preview was accepted (stashed + repaint attempted) — false = dropped
    /// as stale. The Bool is for tests pinning the guards; production callers ignore it.
    @discardableResult
    private func presentResizePreview(
        _ result: SurfaceFrameBuildResult, cols: Int, rows: Int, token: UInt64
    ) -> Bool {
        guard renderGeneration == result.generation,         // not superseded by commitGridSize
              emulatorState.isLatestPreviewToken(token),      // not superseded by a newer preview
              cols == previewCols, rows == previewRows,       // still the current drag target
              window != nil else { return false }
        lastPresentedResult = result
        // The preview replaced the frame WITHOUT a present: the renderer cache still holds the
        // previous frame's rows, so the repaint below takes the cache-populating full path.
        lastPresentedResultIsRendererCoherent = false
        // Present now (sanctioned drag path: the same `repaintLastFrame` that `layout()` drives);
        // when no drawable is free this turn, the next layout pass repaints it instead.
        if !repaintLastFrame() { needsLayout = true }
        return true
    }

    // MARK: - Cursor blink

    // Blink is overlay-cheap: the cursor quad lives in the renderer's per-frame extras and a
    // block cursor's glyph inversion re-encodes exactly its own row (`previousCursor` key diff),
    // so each toggle costs ≤1 encoded row + one present — never a grid rebuild. Pinned by
    // `testCursorBlinkReencodesAtMostTheCursorRow`.
    //
    // The timer exists only while a blink can actually show: focused (first responder in the
    // key window), un-occluded, and in a window. Focus + occlusion transitions re-enter here,
    // so an unfocused/covered pane costs ZERO runloop wakeups instead of ticking forever just
    // to early-out (20 background panes used to wake the main runloop ~40×/s for nothing).
    private func restartBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        // Solid on stop: the unfocused hollow cursor renders steady, and a pane must never
        // strand mid-off-beat (invisible cursor) when its timer goes away.
        cursorBlinkVisible = true
        guard cursorBlinkEnabled, effectivelyFocused, !scheduler.isOccluded else { return }
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Belt-and-braces: transitions stop the timer synchronously, but a tick already
                // queued on the runloop when focus flips must still not toggle.
                guard self.effectivelyFocused else { return }
                self.cursorBlinkVisible.toggle()
                self.scheduleRender()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    /// Test seam: whether the blink timer is currently scheduled (the idle-efficiency
    /// contract — no timer while unfocused or occluded).
    func testingBlinkTimerIsScheduled() -> Bool { blinkTimer != nil }

    /// Reset the cursor to solid after activity (typing/output), matching common terminals.
    private func wakeCursor() {
        guard cursorBlinkEnabled else { return }
        if !cursorBlinkVisible {
            cursorBlinkVisible = true
            scheduleRender()
        }
    }

    // MARK: - SGR text blink (blinking cells)

    /// Start/stop the text-blink phase driver. Called with every presented frame's blink
    /// state and on occlusion changes: the timer exists only while blinking content is
    /// actually visible (no idle wakeups for the overwhelmingly common no-blink case), and
    /// parking always lands on the VISIBLE phase so text can never strand invisible.
    /// Each tick flips the renderer's phase and schedules a render; only rows containing
    /// blink cells re-encode (the renderer dirties exactly its `hasBlink` rows on a phase
    /// mismatch), so a tick costs O(blink rows) — same shape as a cursor blink toggle.
    private func updateTextBlinkTimer(frameHasBlink: Bool) {
        lastFrameHadBlink = frameHasBlink
        let shouldRun = frameHasBlink && !scheduler.isOccluded
        if shouldRun {
            guard textBlinkTimer == nil else { return }
            let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.textBlinkHidden.toggle()
                    self.renderer?.textBlinkHidden = self.textBlinkHidden
                    self.scheduleRender()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            textBlinkTimer = timer
        } else if textBlinkTimer != nil {
            textBlinkTimer?.invalidate()
            textBlinkTimer = nil
            if textBlinkHidden {
                textBlinkHidden = false
                renderer?.textBlinkHidden = false
                scheduleRender()
            }
        }
    }

    // MARK: - Scrollback

    /// Scroll the viewport by whole `lines` (positive = back into history) — keyboard paging and
    /// programmatic scrolls. Routed through the continuous path so a fractional rest position is
    /// preserved (a page-up while half a line into a scroll stays half a line offset).
    private func scrollBy(lines: Int) {
        scrollByContinuous(lines: CGFloat(lines))
    }

    /// Smooth scroll: advance the continuous position `P = scrollOffset - scrollFraction` by
    /// `delta` lines (positive = back into history), clamped to `[0, historyCount]`. The integer
    /// offset is `ceil(P)` — the frame one line further back — and the fraction is the upward
    /// translate that slides it to the exact position. An offset change rebuilds via the existing
    /// shift path; a fraction-only change re-presents the cached frame with a new uniform (the
    /// near-free tick that makes trackpad scrolling pixel-smooth). Clamping to 0 lands exactly on
    /// the live view (fraction 0 — byte-identical frame).
    private func scrollByContinuous(lines delta: CGFloat) {
        guard delta != 0 else { return }
        // Mirror read on the off-main pipeline (see `historyCountMirror`): a precise trackpad
        // fires this at event rate, and a `queue.sync` here would stall every wheel event behind
        // an in-flight parse. Direct read when the emulator is main-confined (legacy pipeline).
        let historyCount = offMainParserFramePipelineEnabled
            ? historyCountMirror
            : emulatorState.emulator.historyCount
        var position = CGFloat(scrollOffset) - scrollFraction + delta
        position = max(0, min(CGFloat(historyCount), position))
        // Snap float dust onto whole lines: P fractionally ABOVE an integer would ceil to the
        // next offset with fraction ≈ 1 — render-identical, but every line-based consumer
        // (hit-test, prompt jump, scrollbar) would report one line further back for that tick.
        let nearest = position.rounded()
        if abs(position - nearest) < 0.0005 { position = nearest }
        // Inline images don't ride the smooth-scroll translate (image quads draw window-relative,
        // outside the scrollPx uniform); quantize to whole lines while any are visible so they
        // never sit misaligned mid-cell. The legacy on-main pipeline quantizes too: it presents
        // without the fraction uniform (and never builds the peek row), so a fractional position
        // there would render one whole line off instead of in between.
        if !offMainParserFramePipelineEnabled
            || lastPresentedResult.map({ !$0.frame.images.isEmpty }) == true {
            position = position.rounded()
        }
        let newOffset = Int(position.rounded(.up))
        let newFraction = CGFloat(newOffset) - position
        guard newOffset != scrollOffset || newFraction != scrollFraction else { return }
        let offsetChanged = newOffset != scrollOffset
        scrollOffset = newOffset
        scrollFraction = newFraction
        // Selection is content-anchored (absolute buffer lines) — scrolling moves the viewport
        // over it, never clears it (#161).
        notifyScrollChanged(historyCount: historyCount)
        if offsetChanged {
            scheduleRender()
        } else if !repaintLastFrame() {
            // Fraction-only tick: the frame is unchanged, only the translate moved. The repaint
            // applies the new uniform over the cached instances; fall back to a build only when
            // there is no presentable cached frame (e.g. generation just changed).
            scheduleRender()
        }
    }

    /// Jump back to the live bottom (e.g. on typing).
    private func snapToBottom() {
        guard scrollOffset != 0 || scrollFraction != 0 else { return }
        scrollOffset = 0
        scrollFraction = 0
        notifyScrollChanged(historyCount: emulatorSync { $0.historyCount })
        scheduleRender()
    }

    /// Tell the host the scroll position changed so it can flash the transient scrollbar.
    private func notifyScrollChanged(historyCount: Int) {
        onScrollChanged?(historyCount - scrollOffset, historyCount + rows, rows)
    }

    // MARK: - Jump to prompt (OSC 133)

    /// Scroll so the nearest shell-prompt row *above* the current top-of-viewport line sits at the
    /// top. No-op without shell-integration marks or when already above the first prompt.
    public func jumpToPreviousPrompt() {
        let (prompts, historyCount) = emulatorSync { ($0.promptRows, $0.historyCount) }
        guard !prompts.isEmpty else { return }
        let topVisible = historyCount - scrollOffset   // buffer index of the top row
        guard let target = prompts.last(where: { $0 < topVisible }) else { return }
        scrollToBufferLine(target)
    }

    /// Scroll so the nearest shell-prompt row *below* the current top-of-viewport line sits at the
    /// top. No-op without marks or when already at/after the last prompt.
    public func jumpToNextPrompt() {
        let (prompts, historyCount) = emulatorSync { ($0.promptRows, $0.historyCount) }
        guard !prompts.isEmpty else { return }
        let topVisible = historyCount - scrollOffset
        guard let target = prompts.first(where: { $0 > topVisible }) else { return }
        scrollToBufferLine(target)
    }

    /// Select the output of the most recently finished command: the lines strictly between
    /// the last two OSC 133 prompt marks (full-width rows; the prompt rows themselves are
    /// excluded). Scrolls to reveal the output when it's outside the viewport. No-op without
    /// two prompt marks, or when the command printed nothing.
    public func selectLastCommandOutput() {
        let (prompts, historyCount) = emulatorSync { ($0.promptRows, $0.historyCount) }
        guard prompts.count >= 2 else { return }
        let lastPrompt = prompts[prompts.count - 1]
        let previousPrompt = prompts[prompts.count - 2]
        let start = previousPrompt + 1
        let end = lastPrompt - 1
        guard start <= end else { return } // the command printed nothing
        selectionGranularity = .character
        selectionRectangular = false
        selectionAnchor = (line: start, column: 0)
        selectionHead = (line: end, column: max(0, columns - 1))
        let top = historyCount - scrollOffset
        if start < top || end >= top + rows { scrollToBufferLine(start) }
        scheduleRender()
    }

    /// Set the scrollback offset so virtual buffer line `index` is the top viewport row.
    private func scrollToBufferLine(_ index: Int) {
        let historyCount = emulatorSync { $0.historyCount }
        let target = max(0, min(historyCount, historyCount - index))
        guard target != scrollOffset || scrollFraction != 0 else { return }
        scrollOffset = target
        scrollFraction = 0 // prompt jumps anchor on a whole line
        notifyScrollChanged(historyCount: historyCount)
        scheduleRender()
    }

    // MARK: - Selection & copy

    /// Raw selection inputs, captured on the main thread WITHOUT resolving the per-granularity
    /// column expansion. The off-main render path resolves the region on the emulator queue (see
    /// `resolveSelectionRegion`) so a `.word` selection never drives `currentSelectionRegion`'s
    /// `emulatorSync` — which, off the queue, `queue.sync`s the MAIN thread behind an in-flight
    /// output feed on every build while the word selection is held (the stall the off-main pipeline
    /// exists to avoid). `Sendable` so the `@Sendable` build closure can capture it.
    private struct RawSelection: Sendable {
        let anchorLine: Int, anchorColumn: Int
        let headLine: Int, headColumn: Int
        let granularity: SelectionGranularity
        let rectangular: Bool
    }

    private var currentRawSelection: RawSelection? {
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        return RawSelection(anchorLine: a.line, anchorColumn: a.column,
                            headLine: h.line, headColumn: h.column,
                            granularity: selectionGranularity, rectangular: selectionRectangular)
    }

    /// Buffer line index of viewport row 0 — the rebase term between the absolute selection
    /// coordinates and viewport rows. Mirror read on the off-main pipeline (same discipline as
    /// `scrollByContinuous`): mouse handlers must never `queue.sync` behind a busy parse.
    private var viewportTopBufferLine: Int {
        (offMainParserFramePipelineEnabled ? historyCountMirror : emulatorState.emulator.historyCount)
            - scrollOffset
    }

    /// Resolve a raw selection into a render region in VIEWPORT rows. PURE — call it ON the
    /// emulator queue (inside the build) so the `.word` expansion reads `wordColumnRange`
    /// directly instead of through a main-stalling `emulatorSync`. Anchors are absolute buffer
    /// lines; rows that rebase outside the viewport simply don't shade (the overlay pass
    /// ignores out-of-range rows), so a partially scrolled-away selection renders its visible
    /// band and nothing else.
    private nonisolated static func resolveSelectionRegion(_ sel: RawSelection?, emulator: TerminalEmulator,
                                                           scrollOffset: Int, columns: Int) -> SelectionRegion? {
        guard let sel else { return nil }
        guard let absolute = resolveAbsoluteSelectionRegion(sel, emulator: emulator, columns: columns) else {
            return nil
        }
        let top = emulator.historyCount - scrollOffset
        switch absolute {
        case let .linear(s):
            return .linear(TerminalSelection((s.startRow - top, s.startColumn),
                                             (s.endRow - top, s.endColumn)))
        case let .block(b):
            return .block(BlockSelection((b.startRow - top, b.startColumn),
                                         (b.endRow - top, b.endColumn)))
        }
    }

    /// The selection region in ABSOLUTE buffer-line space: endpoints ordered, granularity
    /// expansion applied, lines clamped to the retained buffer (a clamped endpoint after
    /// scrollback eviction selects the oldest retained line — copy mode's convention). Shared
    /// by rendering (rebased to viewport rows above) and extraction (read via `bufferLine`).
    private nonisolated static func resolveAbsoluteSelectionRegion(
        _ sel: RawSelection, emulator: TerminalEmulator, columns: Int
    ) -> SelectionRegion? {
        let maxLine = max(0, emulator.bufferLineCount - 1)
        let a = (line: min(max(0, sel.anchorLine), maxLine), column: sel.anchorColumn)
        let h = (line: min(max(0, sel.headLine), maxLine), column: sel.headColumn)
        if sel.rectangular {
            return .block(BlockSelection((a.line, a.column), (h.line, h.column)))
        }
        if sel.granularity == .character {
            return .linear(TerminalSelection((a.line, a.column), (h.line, h.column)))
        }
        // Per-line column extent: the whole row for `.line` (triple-click's LOGICAL-line span
        // across soft wraps is handled at mouse-down by anchoring across the wrapped lines —
        // see `logicalLineBufferRowSpan`), the whitespace-delimited word for `.word` (shared
        // with copy mode), else the single column.
        func unitRange(line: Int, column: Int) -> ClosedRange<Int> {
            switch sel.granularity {
            case .character: return column ... column
            case .line: return 0 ... max(0, columns - 1)
            case .word: return emulator.wordColumnRange(line: line, column: column)
            }
        }
        let lo: (line: Int, column: Int), hi: (line: Int, column: Int)
        if (a.line, a.column) <= (h.line, h.column) { lo = a; hi = h } else { lo = h; hi = a }
        let loRange = unitRange(line: lo.line, column: lo.column)
        let hiRange = unitRange(line: hi.line, column: hi.column)
        if lo.line == hi.line {
            return .linear(TerminalSelection((lo.line, min(loRange.lowerBound, hiRange.lowerBound)),
                                             (lo.line, max(loRange.upperBound, hiRange.upperBound))))
        }
        return .linear(TerminalSelection((lo.line, loRange.lowerBound), (hi.line, hiRange.upperBound)))
    }

    /// The active selection region in viewport rows (nil when nothing is selected), resolved
    /// through the same pure resolver as the off-main build. Only the legacy (main-confined)
    /// render path and copy actions read this; guards that just need "is something selected"
    /// must check `selectionAnchor` instead — this getter can `emulatorSync`.
    private var currentSelectionRegion: SelectionRegion? {
        guard let raw = currentRawSelection else { return nil }
        return emulatorSync {
            Self.resolveSelectionRegion(raw, emulator: $0, scrollOffset: scrollOffset, columns: columns)
        }
    }

    private func clearSelection() {
        selectionGranularity = .character
        selectionRectangular = false
        guard selectionAnchor != nil || selectionHead != nil else { return }
        selectionAnchor = nil
        selectionHead = nil
        scheduleRender()
    }

    /// Map a window-space point to a grid cell, accounting for padding + backing scale.
    /// AppKit view coordinates are bottom-left origin, so the row is measured from the top.
    private func cell(at locationInWindow: NSPoint) -> (row: Int, column: Int)? {
        guard let renderer, columns > 0, rows > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2.0
        let cellW = CGFloat(renderer.cellPixelWidth) / scale
        let cellH = CGFloat(renderer.cellPixelHeight) / scale
        guard cellW > 0, cellH > 0 else { return nil }
        let p = convert(locationInWindow, from: nil)
        let x = p.x - gridOriginPointsX
        // The smooth-scroll translate slides content UP by `scrollFraction` of a cell, so what's
        // visually under the pointer is the content that fraction further down — add it back so
        // clicks/selections land on the row the user sees, not the untranslated grid slot.
        let yFromTop = bounds.height - p.y - gridOriginPointsY + scrollFraction * cellH
        let col = Int((x / cellW).rounded(.down))
        let row = Int((yFromTop / cellH).rounded(.down))
        return (max(0, min(rows - 1, row)), max(0, min(columns - 1, col)))
    }

    /// Mouse goes to the program when it enabled tracking — unless Shift is held, which
    /// always forces local selection (the standard terminal override).
    private func isMouseReporting(_ event: NSEvent) -> Bool {
        inputModes().mouseTrackingEnabled && !event.modifierFlags.contains(.shift)
    }

    private func mouseModifiers(_ event: NSEvent) -> KeyModifiers {
        var mods: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        return mods
    }

    private func reportMouse(_ event: NSEvent, button: MouseButton, kind: MouseEventKind) {
        guard let pos = cell(at: event.locationInWindow) else { return }
        let modes = inputModes()
        emit(inputEncoder.encodeMouse(
            button: button, kind: kind,
            column: pos.column, row: pos.row,
            pixelPosition: modes.mouseSGRPixel ? textAreaPixelPosition(of: event) : nil,
            modifiers: mouseModifiers(event), modes: modes
        ))
    }

    /// Pointer position within the text area in DEVICE pixels (0-based) — the coordinate
    /// space of SGR-pixel mouse reporting (DECSET 1016), consistent with the engine's
    /// `CSI 14 t` report (grid cells × renderer cell pixel size). Clamped into the grid box.
    private func textAreaPixelPosition(of event: NSEvent) -> (x: Int, y: Int)? {
        guard let renderer, columns > 0, rows > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2.0
        let cellH = CGFloat(renderer.cellPixelHeight) / scale
        let p = convert(event.locationInWindow, from: nil)
        // Same mapping as `cell(at:)`, kept un-rounded: points from the grid origin, with the
        // smooth-scroll translate added back so the reported pixel matches what's on screen.
        let xPoints = p.x - gridOriginPointsX
        let yPointsFromTop = bounds.height - p.y - gridOriginPointsY + scrollFraction * cellH
        let maxX = columns * renderer.cellPixelWidth - 1
        let maxY = rows * renderer.cellPixelHeight - 1
        let x = min(max(0, Int((xPoints * scale).rounded(.down))), max(0, maxX))
        let y = min(max(0, Int((yPointsFromTop * scale).rounded(.down))), max(0, maxY))
        return (x: x, y: y)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A press starts a drag-coded sequence; forget the hover-motion dedupe cell so the
        // first post-release move back into it isn't swallowed as a duplicate.
        lastReportedMotionCell = nil
        if copyMode != nil { return } // copy mode is keyboard-driven; ignore clicks
        // ⌘-click opens an OSC 8 hyperlink or an auto-detected URL.
        // ⌘ overrides mouse reporting, the same way Shift overrides it for selection.
        if event.modifierFlags.contains(.command), let pos = cell(at: event.locationInWindow),
           let url = linkURL(atRow: pos.row, column: pos.column) {
            openLink(url)
            return
        }
        if isMouseReporting(event) {
            reportMouse(event, button: .left, kind: .press)
            return
        }
        guard let pos = cell(at: event.locationInWindow) else { return }
        // Click count picks the selection unit (1 = char, 2 = word, 3 = line); Option = rectangle.
        switch event.clickCount {
        case 2: selectionGranularity = .word
        case let n where n >= 3: selectionGranularity = .line
        default: selectionGranularity = .character
        }
        selectionRectangular = event.modifierFlags.contains(.option)
        if event.clickCount >= 3, !selectionRectangular {
            // Triple-click selects the whole LOGICAL line across soft wraps (Ghostty/iTerm2/kitty),
            // not just the display row. Anchor across the wrapped buffer lines; `.line` granularity
            // then fills each to full width and the multi-row linear region covers the logical line.
            let span = logicalLineBufferRowSpan(at: pos.row)
            selectionAnchor = (line: span.lowerBound, column: 0)
            selectionHead = (line: span.upperBound, column: max(0, columns - 1))
        } else {
            let line = viewportTopBufferLine + pos.row
            selectionAnchor = (line: line, column: pos.column)
            selectionHead = (line: line, column: pos.column)
        }
        scheduleRender()
    }

    /// The buffer-line span of the logical (soft-wrapped) line at viewport `row` — the lines a
    /// triple-click selects. Absolute (content-anchored), and no longer clamped to the viewport:
    /// the off-screen tail of a wrapped line is part of the selection too.
    private func logicalLineBufferRowSpan(at row: Int) -> ClosedRange<Int> {
        emulatorSync { emu in
            let base = emu.historyCount - scrollOffset // buffer-line index of viewport row 0
            return emu.logicalLineRowSpan(virtualLine: base + row)
        }
    }

    /// The clickable URL at a grid cell (OSC 8 hyperlink first, else an auto-detected URL).
    private func linkURL(atRow row: Int, column col: Int) -> String? {
        linkRange(atRow: row, column: col)?.url
    }

    /// The clickable link at a grid cell *and* its column span — an OSC 8 hyperlink (the run of
    /// adjacent cells sharing its id) first, else an auto-detected URL in the row text. The row is
    /// built one character per cell so `column`/the returned range map directly to grid columns.
    private func linkRange(atRow row: Int, column col: Int) -> (url: String, columns: Range<Int>)? {
        emulatorSync { emulator in
            let grid = scrollOffset > 0 ? emulator.readGrid(scrollbackOffset: scrollOffset) : emulator.readGrid()
            guard row >= 0, row < grid.rows, col >= 0, col < grid.cols else { return nil }
            if let cell = grid.cell(row: row, col: col), cell.hyperlinkID != 0,
               let url = emulator.hyperlinkURL(id: cell.hyperlinkID) {
                var lo = col, hi = col
                while lo > 0, grid.cell(row: row, col: lo - 1)?.hyperlinkID == cell.hyperlinkID { lo -= 1 }
                while hi + 1 < grid.cols, grid.cell(row: row, col: hi + 1)?.hyperlinkID == cell.hyperlinkID { hi += 1 }
                return (url, lo ..< (hi + 1))
            }
            var line = ""
            line.reserveCapacity(grid.cols)
            for c in 0 ..< grid.cols {
                guard let cell = grid.cell(row: row, col: c), cell.width != .spacerTail else { line.append(" "); continue }
                line.unicodeScalars.append(cell.codepoint == 0 ? " " : (Unicode.Scalar(cell.codepoint) ?? " "))
            }
            return URLDetection.match(in: line, at: col)
        }
    }

    /// Open a clicked link, restricted to safe schemes so terminal output can't trigger a
    /// surprising handler (e.g. a custom app scheme) on ⌘-click. No `file:` — an OSC 8
    /// hyperlink comes from terminal output (possibly a remote host), and opening an
    /// arbitrary local path via NSWorkspace executes .app bundles and .command scripts.
    private func openLink(_ string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "ftps"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    public override func mouseDragged(with event: NSEvent) {
        if copyMode != nil { return }
        if isMouseReporting(event) {
            // Only report motion when the app asked for drag / any-motion tracking.
            let modes = inputModes()
            if modes.mouseDrag || modes.mouseAny {
                reportMouse(event, button: .left, kind: .drag)
            }
            return
        }
        guard selectionAnchor != nil, let pos = cell(at: event.locationInWindow) else { return }
        selectionHead = (line: viewportTopBufferLine + pos.row, column: pos.column)
        scheduleRender()
    }

    public override func mouseUp(with event: NSEvent) {
        if copyMode != nil { return }
        if isMouseReporting(event) {
            reportMouse(event, button: .left, kind: .release)
            return
        }
        // A single-cell *character* click with no drag clears; a word/line click (or any drag)
        // makes a real selection that copy-on-select copies.
        if let a = selectionAnchor, let h = selectionHead, a == h, selectionGranularity == .character {
            clearSelection()
            return
        }
        if copyOnSelect { copySelection() }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if isMouseReporting(event) { reportMouse(event, button: .right, kind: .press) }
        else { super.rightMouseDown(with: event) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        if isMouseReporting(event) { reportMouse(event, button: .right, kind: .release) }
        else { super.rightMouseUp(with: event) }
    }

    public override func otherMouseDown(with event: NSEvent) {
        if isMouseReporting(event) {
            reportMouse(event, button: .middle, kind: .press)
        } else if event.buttonNumber == 2 {
            // Middle-click pastes the current selection (the X11/Ghostty primary-paste
            // convention), falling back to the clipboard. Routed through pasteText so
            // bracketed paste and paste protection apply exactly like ⌘V.
            if let text = selectionTextIfAny() ?? NSPasteboard.general.string(forType: .string),
               !text.isEmpty {
                pasteText(text)
            }
        } else {
            super.otherMouseDown(with: event)
        }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if isMouseReporting(event) { reportMouse(event, button: .middle, kind: .release) }
        else { super.otherMouseUp(with: event) }
    }

    // MARK: - Link hover (⌘-hover affordance)

    private func cellSizePoints() -> (w: CGFloat, h: CGFloat)? {
        guard let renderer else { return nil }
        let scale = window?.backingScaleFactor ?? 2.0
        let w = CGFloat(renderer.cellPixelWidth) / scale
        let h = CGFloat(renderer.cellPixelHeight) / scale
        guard w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// The view-space rect (bottom-left origin, matching `cell(at:)`'s inverse) covering a grid
    /// `row` and half-open `columns` span.
    private func cellRect(row: Int, columns: Range<Int>) -> CGRect? {
        guard let (w, h) = cellSizePoints(), !columns.isEmpty else { return nil }
        let x = gridOriginPointsX + CGFloat(columns.lowerBound) * w
        let y = bounds.height - gridOriginPointsY - CGFloat(row + 1) * h
        return CGRect(x: x, y: y, width: CGFloat(columns.count) * w, height: h)
    }

    private func hoveredLinkRect() -> CGRect? {
        guard let link = hoveredLink else { return nil }
        return cellRect(row: link.row, columns: link.columns)
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateLinkHover(at: event.locationInWindow, modifiers: event.modifierFlags)
        reportAnyEventMotionIfArmed(event)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearLinkHover()
        lastReportedMotionCell = nil
    }

    /// Last grid cell reported for button-less motion, deduping any-event tracking to one
    /// report per cell crossed — AppKit delivers `mouseMoved` at event rate, and per-cell is
    /// the protocol's resolution (kept even in SGR-pixel mode so a wiggle inside one cell
    /// can't flood the PTY).
    private var lastReportedMotionCell: (row: Int, column: Int)?

    /// DECSET 1003 any-event tracking: report pointer MOTION with no button held. Shift
    /// keeps its standard local-override meaning, and copy mode owns the surface.
    private func reportAnyEventMotionIfArmed(_ event: NSEvent) {
        guard copyMode == nil, inputModes().mouseAny,
              !event.modifierFlags.contains(.shift) else { return }
        guard let pos = cell(at: event.locationInWindow) else { return }
        if let last = lastReportedMotionCell, last == pos { return }
        lastReportedMotionCell = pos
        reportMouse(event, button: .left, kind: .move) // button is ignored for .move (base code 3)
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Pressing/releasing ⌘ over a stationary pointer toggles whether the link is "hot".
        if let window {
            updateLinkHover(at: window.mouseLocationOutsideOfEventStream, modifiers: event.modifierFlags)
        }
        reportModifierKeyIfNeeded(event)
    }

    /// Physical modifier keycodes currently held — used to tell press from release in
    /// `flagsChanged` (which fires for both, with no inherent direction).
    private var pressedModifierKeyCodes: Set<UInt16> = []

    /// Report a modifier key (Shift/Ctrl/Alt/Cmd/CapsLock) as its own key event when a program
    /// enabled the Kitty protocol's "report all keys as escape codes" flag (0b1000). Release events
    /// additionally require "report event types" (0b10). No-op otherwise — modifiers normally emit
    /// nothing on their own.
    private func reportModifierKeyIfNeeded(_ event: NSEvent) {
        let modes = inputModes()
        guard modes.kittyKeyboardFlags & 0b1000 != 0 else { pressedModifierKeyCodes.removeAll(); return }
        guard copyMode == nil, let key = Self.modifierSpecialKey(forKeyCode: event.keyCode) else { return }
        // flagsChanged toggles: if we already recorded this key down, this event is its release.
        let isPress: Bool
        if pressedModifierKeyCodes.contains(event.keyCode) {
            pressedModifierKeyCodes.remove(event.keyCode)
            isPress = false
        } else {
            pressedModifierKeyCodes.insert(event.keyCode)
            isPress = true
        }
        if !isPress, modes.kittyKeyboardFlags & 0b10 == 0 { return } // release needs event-types
        emit(inputEncoder.encode(key, modifiers: [], event: isPress ? .press : .release, modes: modes))
    }

    /// Map a macOS virtual keycode for a modifier key to its Kitty `SpecialKey`. Left/right are
    /// distinguished by keycode (the device-independent modifier flags can't tell them apart).
    private static func modifierSpecialKey(forKeyCode code: UInt16) -> SpecialKey? {
        switch code {
        case 56: return .leftShift       // kVK_Shift
        case 60: return .rightShift      // kVK_RightShift
        case 59: return .leftControl     // kVK_Control
        case 62: return .rightControl    // kVK_RightControl
        case 58: return .leftAlt         // kVK_Option
        case 61: return .rightAlt        // kVK_RightOption
        case 55: return .leftSuper       // kVK_Command
        case 54: return .rightSuper      // kVK_RightCommand
        case 57: return .capsLock        // kVK_CapsLock
        default: return nil
        }
    }

    /// A link is only highlighted while ⌘ is held (matching ⌘-click open) and the program
    /// isn't grabbing the mouse.
    private func updateLinkHover(at locationInWindow: NSPoint, modifiers: NSEvent.ModifierFlags) {
        // `cell(at:)` clamps to the grid, so first require the pointer to actually be inside us
        // (⌘ can be pressed while the pointer rests over another pane).
        guard copyMode == nil, modifiers.contains(.command),
              bounds.contains(convert(locationInWindow, from: nil)),
              let pos = cell(at: locationInWindow),
              let link = linkRange(atRow: pos.row, column: pos.column)
        else { clearLinkHover(); return }
        if let current = hoveredLink, current.row == pos.row, current.columns == link.columns { return }
        hoveredLink = (row: pos.row, columns: link.columns)
        refreshLinkUnderline()
        window?.invalidateCursorRects(for: self)
    }

    private func clearLinkHover() {
        guard hoveredLink != nil else { return }
        hoveredLink = nil
        refreshLinkUnderline()
        window?.invalidateCursorRects(for: self)
    }

    private func refreshLinkUnderline() {
        // Disable implicit animations so the underline snaps to the pointer instead of sliding.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let rect = hoveredLinkRect() {
            let thickness = max(1, (cellSizePoints()?.h ?? 16) * 0.07)
            linkUnderlineLayer.frame = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness)
            linkUnderlineLayer.isHidden = false
        } else {
            linkUnderlineLayer.isHidden = true
        }
        CATransaction.commit()
    }

    // MARK: - Find (Cmd+F)

    public func beginFind() { findActive = true }

    /// Close the find bar: drop matches + highlights (the bar stays a host concern).
    public func endFind() {
        guard findActive else { return }
        findActive = false
        findMatches = []
        findCurrentIndex = 0
        onFindResultsChanged?(0, 0)
        scheduleRender()
    }

    /// Run/refresh the search for `query` (incremental as the user types), honoring the find bar's
    /// match mode (`options`). Empty clears matches.
    public func updateFind(query: String, options: TerminalBufferSearchOptions = .default) {
        findActive = true
        if query.isEmpty {
            findMatches = []
            findCurrentIndex = 0
        } else {
            findMatches = emulatorSync { emulator in
                TerminalBufferSearch.matches(query: query, options: options, lineCount: emulator.bufferLineCount) { emulator.bufferLine($0) }
            }
            findCurrentIndex = 0
            if !findMatches.isEmpty { scrollToCurrentMatch() }
        }
        onFindResultsChanged?(findMatches.isEmpty ? 0 : findCurrentIndex + 1, findMatches.count)
        scheduleRender()
    }

    public func findNext() { advanceFind(by: 1) }
    public func findPrevious() { advanceFind(by: -1) }

    private func advanceFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        let n = findMatches.count
        findCurrentIndex = ((findCurrentIndex + delta) % n + n) % n
        scrollToCurrentMatch()
        onFindResultsChanged?(findCurrentIndex + 1, n)
        scheduleRender()
    }

    /// Scroll so the current match sits a little below the top of the viewport (context above it).
    private func scrollToCurrentMatch() {
        guard findMatches.indices.contains(findCurrentIndex) else { return }
        let line = findMatches[findCurrentIndex].bufferLine
        scrollToBufferLine(max(0, line - max(0, rows / 3)))
    }

    /// Viewport-relative highlight spans for the matches currently on screen. `nonisolated` +
    /// pure so the off-main render path can call it on its worker queue.
    private nonisolated static func viewportFindHighlights(
        _ matches: [TerminalBufferMatch], scrollOffset: Int, historyCount: Int, rows: Int
    ) -> [TerminalSelection] {
        guard !matches.isEmpty, rows > 0 else { return [] }
        let topVisible = historyCount - scrollOffset // buffer index of the top viewport row
        var hits: [TerminalSelection] = []
        for m in matches where !m.columns.isEmpty {
            let row = m.bufferLine - topVisible
            if row >= 0, row < rows {
                hits.append(TerminalSelection((row, m.columns.lowerBound), (row, m.columns.upperBound - 1)))
            }
        }
        return hits
    }

    public override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY != 0 { clearLinkHover() }
        // In copy mode, the wheel moves the copy-mode cursor through scrollback.
        if copyMode != nil, let renderer, event.scrollingDeltaY != 0 {
            let scale = window?.backingScaleFactor ?? 2.0
            let cellH = max(1, CGFloat(renderer.cellPixelHeight) / scale)
            let lines = consumeWheelLines(event, cellHeight: cellH)
            guard lines != 0 else { return }
            let action: CopyModeAction = lines > 0 ? .cursorUp : .cursorDown
            for _ in 0 ..< abs(lines) { handleCopyModeAction(action) }
            return
        }
        if isMouseReporting(event) {
            guard let renderer else { return }
            let scale = window?.backingScaleFactor ?? 2.0
            // One wheel report per *line* of travel (cell-height accumulated, remainder carried),
            // not per NSEvent — a trackpad fires a ~120Hz stream of tiny deltas plus momentum
            // events, and reporting each one flooded TUIs (Claude Code) with wheel events, making
            // scroll feel hair-trigger. Matches Ghostty's pending-scroll accumulation.
            let cellH = max(1, CGFloat(renderer.cellPixelHeight) / scale)
            let lines = consumeWheelLines(event, cellHeight: cellH)
            if lines != 0 {
                let button: MouseButton = lines > 0 ? .wheelUp : .wheelDown
                for _ in 0 ..< min(abs(lines), 32) { reportMouse(event, button: button, kind: .press) }
            }
            // Horizontal wheel: buttons 66/67, one report per cell-width column (Ghostty parity).
            let cellW = max(1, CGFloat(renderer.cellPixelWidth) / scale)
            let cols = consumeWheelColumns(event, cellWidth: cellW)
            if cols != 0 {
                let button: MouseButton = cols > 0 ? .wheelLeft : .wheelRight
                for _ in 0 ..< min(abs(cols), 32) { reportMouse(event, button: button, kind: .press) }
            }
            return
        }
        // Local scrollback: positive deltaY (content moves down) scrolls back into history.
        guard event.scrollingDeltaY != 0, let renderer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let cellH = max(1, CGFloat(renderer.cellPixelHeight) / scale)
        // The alternate screen has no scrollback — synthesize arrow keys instead (DECSET
        // 1007 "alternate scroll", on by default) so the wheel scrolls less/man/vim when
        // the program didn't enable mouse reporting (that case already returned above).
        // Arrow synthesis is inherently line-based, so it keeps the whole-line accumulator;
        // local scrollback below scrolls by the continuous (pixel-smooth) delta instead.
        let onAltScreen = inputAltScreenActive()
        let modes = inputModes()
        if onAltScreen, modes.alternateScroll {
            let lines = consumeWheelLines(event, cellHeight: cellH)
            guard lines != 0 else { return }
            let key: SpecialKey = lines > 0 ? .up : .down
            let perLine = inputEncoder.encode(key, modifiers: [], modes: modes)
            guard !perLine.isEmpty else { return }
            // Cap one event's burst (don't flood the PTY on a violent fling) but carry
            // the excess back into the remainder so momentum isn't silently truncated.
            let send = min(abs(lines), 32)
            let excess = abs(lines) - send
            if excess > 0 { wheelLineRemainder += CGFloat(lines > 0 ? excess : -excess) }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(perLine.count * send)
            for _ in 0 ..< send { bytes.append(contentsOf: perLine) }
            emit(bytes)
            return
        }
        scrollByContinuous(lines: continuousWheelLines(event, cellHeight: cellH))
    }

    /// Continuous (sub-line) wheel delta in lines for local-scrollback smooth scrolling. Precise
    /// (trackpad) deltas are pixel-based; the fraction itself is the carry, so no remainder
    /// accumulator is needed. Non-precise mouse wheels keep the classic whole-notch step
    /// (clamped to a full tick like `consumeWheelLines`) — a clicky wheel jumping 3 lines per
    /// notch is the expected feel; only the trackpad scrolls by pixels.
    private func continuousWheelLines(_ event: NSEvent, cellHeight: CGFloat) -> CGFloat {
        let delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { return delta / cellHeight * scrollMultiplier }
        let ticks = delta > 0 ? max(delta, 1) : min(delta, -1)
        return ticks * Self.mouseWheelLinesPerTick * scrollMultiplier
    }

    /// Convert a wheel/trackpad event into a signed whole-line scroll count, carrying the
    /// sub-line remainder across events. Precise (trackpad) deltas are pixel-based, so dividing
    /// by the cell height maps a line's worth of finger travel to one line *and* lets small
    /// movements accumulate — the old `max(1, …rounded())` forced a full line per event, which
    /// made trackpad scrolling feel hair-trigger. Non-precise mouse wheels report in line units,
    /// scaled to the classic 3-line notch.
    private func consumeWheelLines(_ event: NSEvent, cellHeight: CGFloat) -> Int {
        let delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            wheelLineRemainder += delta / cellHeight * scrollMultiplier
        } else {
            // macOS simulates acceleration on non-precise wheels by ramping the delta from 0.1
            // upward — a slow single notch would otherwise accumulate 0.3 lines and do nothing
            // until the fourth click. Clamp a notch to at least one full tick (Ghostty parity).
            let ticks = delta > 0 ? max(delta, 1) : min(delta, -1)
            wheelLineRemainder += ticks * Self.mouseWheelLinesPerTick * scrollMultiplier
        }
        let whole = wheelLineRemainder < 0 ? wheelLineRemainder.rounded(.up) : wheelLineRemainder.rounded(.down)
        wheelLineRemainder -= whole
        return Int(whole)
    }

    /// Horizontal counterpart of `consumeWheelLines` for mouse-reported wheel-left/right: precise
    /// deltas accumulate by cell width (remainder carried); non-precise ticks map 1:1 to columns.
    private func consumeWheelColumns(_ event: NSEvent, cellWidth: CGFloat) -> Int {
        let delta = event.scrollingDeltaX
        guard delta != 0 else { return 0 }
        if event.hasPreciseScrollingDeltas {
            wheelColumnRemainder += delta / cellWidth
            let whole = wheelColumnRemainder < 0 ? wheelColumnRemainder.rounded(.up) : wheelColumnRemainder.rounded(.down)
            wheelColumnRemainder -= whole
            return Int(whole)
        }
        return Int(delta.rounded())
    }

    /// Standard responder copy (Edit ▸ Copy / ⌘C via the menu).
    @objc public func copy(_ sender: Any?) {
        copySelection()
    }

    /// Standard responder cut (Edit ▸ Cut / ⌘X). A terminal's scrollback is read-only, so cut
    /// behaves as copy — without this, the Edit-menu Cut item (which targets `cut:`) no-ops.
    @objc public func cut(_ sender: Any?) {
        copySelection()
    }

    /// Standard responder paste (Edit ▸ Paste / ⌘V). Sends the clipboard text to the PTY,
    /// wrapped in bracketed-paste markers when the program enabled DECSET 2004 (so shells and
    /// editors treat it as a literal paste, not typed input). Newlines normalize to CR (the
    /// Enter byte) so multi-line pastes run line by line.
    ///
    /// When the clipboard holds no text but an image (a screenshot) or a copied file, the image is
    /// written to a temp PNG and its shell-quoted path is pasted instead — so programs that accept
    /// image-file paths (Claude Code, etc.) attach it. Mirrors the file-drop path.
    @objc public func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        // Text fast path.
        if let raw = pasteboard.string(forType: .string), !raw.isEmpty {
            pasteText(raw)
            return
        }
        // Image on the clipboard → write a temp PNG, paste its quoted path.
        if let path = Self.writePastedImage(from: pasteboard) {
            pasteText(Self.shellQuotedPath(path))
            return
        }
        // A file copied in Finder (⌘C → ⌘V) → paste the quoted path(s), like a drag-drop.
        let text = Self.droppedPathText(for: Self.droppedFileURLs(from: pasteboard))
        if !text.isEmpty { pasteText(text) }
    }

    /// If the pasteboard holds a valid image, write it to the pasted-images directory as a PNG and
    /// return the file path. Prefers raw PNG bytes; converts TIFF / other image reps via a bitmap
    /// rep. Returns nil when there's no usable image. Validation is via `NSBitmapImageRep` (not the
    /// engine's `ImageDecoder`, whose inline-display pixel cap would wrongly reject a high-res
    /// Retina/Pro-Display screenshot — pasting a *path* has no such limit).
    static func writePastedImage(from pasteboard: NSPasteboard) -> String? {
        guard let png = pngImageData(from: pasteboard) else { return nil }
        let dir = HarnessPaths.pastedImagesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prunePastedImages(in: dir)
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("pasted-\(stamp)-\(UUID().uuidString.prefix(8)).png")
        do { try png.write(to: url); return url.path } catch { return nil }
    }

    /// Best-effort PNG bytes for whatever image the pasteboard carries (screenshot = PNG/TIFF).
    private static func pngImageData(from pasteboard: NSPasteboard) -> Data? {
        // A screenshot is already PNG — trust the raw bytes once they parse as an image.
        if let png = pasteboard.data(forType: .png), NSBitmapImageRep(data: png) != nil {
            return png
        }
        // Otherwise re-encode a TIFF / NSImage payload to PNG.
        let tiff = pasteboard.data(forType: .tiff) ?? NSImage(pasteboard: pasteboard)?.tiffRepresentation
        if let tiff, let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// Drop pasted-image files older than a day so the directory can't grow unbounded.
    private static func prunePastedImages(in dir: URL, olderThan maxAge: TimeInterval = 24 * 60 * 60) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? fm.removeItem(at: url) }
        }
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        pathDropOperation(for: sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        pathDropOperation(for: sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.droppedFileURLs(from: sender.draggingPasteboard)
        let text = Self.droppedPathText(for: urls)
        guard !text.isEmpty else { return false }
        window?.makeFirstResponder(self)
        pasteText(text)
        return true
    }

    private func pathDropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard
            sender.draggingSourceOperationMask.contains(.copy),
            !Self.droppedFileURLs(from: sender.draggingPasteboard).isEmpty
        else { return [] }
        return .copy
    }

    private func pasteText(_ raw: String) {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        // Paste protection: confirm risky text when the program hasn't enabled bracketed paste
        // (which would otherwise run embedded newlines as commands the moment they're pasted).
        let bracketed = inputModes().bracketedPaste
        if pasteProtection, !bracketed, Self.isUnsafePaste(normalized), let window {
            confirmPaste(normalized, in: window)
            return
        }
        deliverPaste(normalized)
    }

    private func deliverPaste(_ normalized: String) {
        snapToBottom()
        clearSelection()
        emit(inputEncoder.encodePaste(normalized, modes: inputModes()))
    }

    /// Unsafe = contains a line break (would run as a command without bracketed paste) or another
    /// control character. Newlines are already normalized to `\r` before this check.
    private static func isUnsafePaste(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" }
    }

    private func confirmPaste(_ normalized: String, in window: NSWindow) {
        let lineCount = normalized.split(separator: "\r", omittingEmptySubsequences: false).count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = lineCount > 1 ? "Paste \(lineCount) lines into the terminal?" : "Paste into the terminal?"
        alert.informativeText = "The clipboard contains line breaks or control characters that can run commands immediately. Review before pasting."
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.deliverPaste(normalized)
        }
    }

    /// Select the entire visible viewport (Edit ▸ Select All / ⌘A).
    @objc public override func selectAll(_ sender: Any?) {
        guard rows > 0, columns > 0 else { return }
        selectionGranularity = .character
        selectionRectangular = false
        let top = viewportTopBufferLine
        selectionAnchor = (line: top, column: 0)
        selectionHead = (line: top + rows - 1, column: columns - 1)
        scheduleRender()
    }

    /// Right-click context menu (Copy / Paste / Select All). Suppressed while the program is
    /// capturing the mouse (unless Shift forces local handling), matching the selection rules.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard !isMouseReporting(event) else { return nil }
        let menu = NSMenu()
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)
        menu.addItem(.separator())
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        return menu
    }

    private func copySelection() {
        guard let text = selectionTextIfAny() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onCopy?(text)
    }

    /// The current selection's text, or nil when there is no selection (or it's empty).
    /// Extracted in ABSOLUTE buffer-line space via `bufferLine` — after scrolling (or new
    /// output) the selection can extend beyond the current viewport, where the old
    /// viewport-snapshot read would have come back blank (#161).
    private func selectionTextIfAny() -> String? {
        guard let raw = currentRawSelection else { return nil }
        let text = emulatorSync { emu -> String in
            guard let region = Self.resolveAbsoluteSelectionRegion(raw, emulator: emu, columns: columns)
            else { return "" }
            switch region {
            case let .linear(sel): return Self.selectedText(sel, emulator: emu)
            case let .block(blk): return Self.blockSelectedText(blk, emulator: emu)
            }
        }
        return text.isEmpty ? nil : text
    }

    /// Extract the selected text (region rows = absolute buffer lines): per line, the in-range
    /// columns, skipping the trailing spacer of wide chars, trailing whitespace trimmed, rows
    /// joined by \n.
    private nonisolated static func selectedText(_ sel: TerminalSelection, emulator: TerminalEmulator) -> String {
        var lines: [String] = []
        for row in sel.startRow ... sel.endRow {
            let cells = emulator.bufferLine(row)
            let startCol = (row == sel.startRow) ? sel.startColumn : 0
            let endCol = (row == sel.endRow) ? sel.endColumn : cells.count - 1
            lines.append(rowText(cells: cells, startCol: startCol, endCol: endCol))
        }
        return lines.joined(separator: "\n")
    }

    /// Extract a rectangular (block) selection: the same column span on every line, joined by \n.
    private nonisolated static func blockSelectedText(_ blk: BlockSelection, emulator: TerminalEmulator) -> String {
        (blk.startRow ... blk.endRow)
            .map { rowText(cells: emulator.bufferLine($0), startCol: blk.startColumn, endCol: blk.endColumn) }
            .joined(separator: "\n")
    }

    /// One buffer line's text over `[startCol, endCol]` (clamped to the line): drop wide-char
    /// spacer tails, blanks → space, trailing whitespace trimmed.
    private nonisolated static func rowText(cells: [TerminalGridCell], startCol: Int, endCol: Int) -> String {
        var line = ""
        var col = max(0, startCol)
        let last = min(endCol, cells.count - 1)
        while col <= last {
            let cell = cells[col]
            if cell.width == .spacerTail { col += 1; continue }
            if cell.codepoint != 0 {
                line += cell.cluster // base + combining marks
            } else {
                line += " "
            }
            col += 1
        }
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    // MARK: - IME preedit

    /// Draw the marked (composing) text over the grid starting at the cursor, and park the
    /// cursor at its end. Combining marks (Thai vowels/tones, accents) are folded onto the base
    /// cell — never given their own column — so composing Thai through the IME renders the same as
    /// committed text, instead of dropping vowels / exploding tone marks.
    private func overlayPreedit(into frame: inout TerminalFrame) {
        Self.applyPreedit(into: &frame, text: markedText, builder: frameBuilder,
                          canvasForeground: canvasForeground, canvasBackground: canvasBackground)
    }

    /// Per-row fingerprint of the cell-overlay pass (selection + find shading + IME preedit):
    /// what the pass paints on each row, hashed from the overlay GEOMETRY (no cell walks). Two
    /// builds whose fingerprints agree for a row shaded it identically, so the rows whose
    /// fingerprint changed — plus rows that left the overlay — are exactly the extra render
    /// damage the pass needs. A selection drag therefore re-encodes the rows it crossed, not
    /// the grid. Keys exist only for rows the overlay touches now.
    nonisolated static func overlayRowKeys(
        selection: SelectionRegion?,
        findHits: [TerminalSelection],
        preedit: String,
        preeditCursor: (row: Int, column: Int),
        rows: Int, cols: Int
    ) -> [Int: UInt64] {
        var keys: [Int: UInt64] = [:]
        func fold(_ row: Int, _ value: UInt64) {
            guard row >= 0, row < rows else { return }
            let h = keys[row] ?? 0xCBF2_9CE4_8422_2325 // FNV-64 offset basis
            keys[row] = (h ^ value) &* 0x0000_0100_0000_01B3
        }
        // Column extents pack into one word; the tag keeps a selection span from ever colliding
        // with an identical find span (they shade with different colors).
        func pack(_ a: Int, _ b: Int, _ tag: UInt64) -> UInt64 {
            (UInt64(UInt32(bitPattern: Int32(a))) << 34)
                ^ (UInt64(UInt32(bitPattern: Int32(b))) << 3) ^ tag
        }
        switch selection {
        case let .linear(s):
            if s.endRow >= 0, s.startRow < rows {
                for row in max(0, s.startRow) ... min(rows - 1, s.endRow) {
                    let a = row == s.startRow ? s.startColumn : 0
                    let b = row == s.endRow ? s.endColumn : cols - 1
                    fold(row, pack(a, b, 1))
                }
            }
        case let .block(b):
            if b.endRow >= 0, b.startRow < rows {
                for row in max(0, b.startRow) ... min(rows - 1, b.endRow) {
                    fold(row, pack(b.startColumn, b.endColumn, 2))
                }
            }
        case nil:
            break
        }
        for hit in findHits where hit.endRow >= 0 && hit.startRow < rows {
            for row in max(0, hit.startRow) ... min(rows - 1, hit.endRow) {
                let a = row == hit.startRow ? hit.startColumn : 0
                let b = row == hit.endRow ? hit.endColumn : cols - 1
                fold(row, pack(a, b, 3))
            }
        }
        if !preedit.isEmpty {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in preedit.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            fold(preeditCursor.row, h ^ pack(preeditCursor.column, 0, 4))
        }
        return keys
    }

    nonisolated private static func applyPreedit(
        into frame: inout TerminalFrame,
        text: String,
        builder: FrameBuilder,
        canvasForeground: RGBColor,
        canvasBackground: RGBColor
    ) {
        let row = frame.cursor.row
        guard row >= 0, row < frame.rows else { return }
        var col = frame.cursor.column
        let fg = builder.renderColor(canvasForeground)
        let bg = builder.renderColor(canvasBackground)
        var lastBaseIdx: Int? = nil
        for scalar in text.unicodeScalars {
            // Zero-width scalar: fold a TRUE combining mark onto the preceding preedit base cell
            // (mirrors the engine's attachCombining); drop a non-extending format scalar (ZWSP, BOM,
            // bidi) so the cell's cluster stays one grapheme. Never advances the column.
            if CharacterWidth.width(of: scalar) == 0 {
                if scalar.properties.isGraphemeExtend, let bi = lastBaseIdx {
                    if frame.cells[bi].combining0 == 0 { frame.cells[bi].combining0 = scalar.value }
                    else if frame.cells[bi].combining1 == 0 { frame.cells[bi].combining1 = scalar.value }
                }
                continue
            }
            let width = max(1, CharacterWidth.width(of: scalar))
            guard col >= 0, col + width <= frame.columns else { break }
            let idx = row * frame.columns + col
            guard idx >= 0, idx < frame.cells.count else { break }
            frame.cells[idx].codepoint = scalar.value
            frame.cells[idx].combining0 = 0
            frame.cells[idx].combining1 = 0
            frame.cells[idx].foreground = fg
            frame.cells[idx].underline = .single
            frame.cells[idx].width = (width == 2) ? .wide : .normal
            // Preedit sits on the *canvas* background: reset the background to it and clear
            // `drawBackground` (canvas cells draw no quad, so window translucency is preserved).
            // Without this the cell kept whatever the overlay pass painted — composing over a
            // selection or find hit rendered the preedit indistinguishable from highlighted text.
            frame.cells[idx].background = bg
            frame.cells[idx].drawBackground = false
            // Mark the trailing cell of a wide composing glyph as its spacer.
            if width == 2, idx + 1 < frame.cells.count {
                frame.cells[idx + 1].codepoint = 0
                frame.cells[idx + 1].width = .spacerTail
                frame.cells[idx + 1].underline = .single
                frame.cells[idx + 1].background = bg
                frame.cells[idx + 1].drawBackground = false
            }
            lastBaseIdx = idx
            col += width
        }
        frame.cursor.column = min(col, frame.columns - 1)
    }

    // MARK: - Input

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        focused = true
        cursorBlinkVisible = true
        focusStateChanged()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        focused = false
        // A modifier released while we're unfocused never reaches `flagsChanged`, so drop the
        // press-tracking state to keep Kitty modifier-key press/release reporting in sync on return.
        pressedModifierKeyCodes.removeAll()
        focusStateChanged()
        return true
    }

    /// React to any change of the effective focus state (first responder × key window):
    /// repaint (hollow cursor) and report DECSET 1004 focus in/out to the program exactly
    /// once per transition. Programs that enabled it (vim, tmux, …) get `CSI I` on
    /// focus-in and `CSI O` on focus-out.
    private func focusStateChanged() {
        let now = effectivelyFocused
        if lastReportedFocus != now {
            lastReportedFocus = now
            if now { cursorBlinkVisible = true; onBecameFocused?() }
            if inputModes().focusReporting {
                emit([0x1B, 0x5B, now ? 0x49 : 0x4F]) // ESC [ I / ESC [ O
            }
            // Blink timer lives only while focused (idle efficiency): start on focus-in,
            // stop (cursor solid) on focus-out — see `restartBlinkTimer`.
            restartBlinkTimer()
        }
        scheduleRender()
    }

    public override func keyDown(with event: NSEvent) {
        // Mouse-hide-while-typing (Ghostty): a typing keystroke hides the cursor until the mouse
        // next moves. Skip bare ⌘-shortcuts — those are app commands, not text input. AppKit
        // auto-restores the cursor on the next mouse move, so this is self-correcting.
        if mouseHideWhileTyping, !event.modifierFlags.contains(.command) {
            NSCursor.setHiddenUntilMouseMoves(true)
        }
        // Copy mode is modal: it consumes every key (motions, search entry, copy/cancel)
        // and nothing reaches the PTY. ⌘ shortcuts still fall through to the app.
        if copyMode != nil, !event.modifierFlags.contains(.command) {
            handleCopyModeKey(event)
            return
        }
        // Let the app handle Command shortcuts (menus, palette, etc.).
        if event.modifierFlags.contains(.command) {
            // ⌘ + an editing key drives readline line-editing (⌘ is otherwise reserved for the
            // app), matching macOS terminal convention: ⌘⌫ = delete to line start (^U), ⌘← / ⌘→ =
            // line start / end (^A / ^E). Other ⌘ keys keep falling through to the app.
            if let special = Self.specialKey(for: event) {
                let lineEdit: [UInt8]?
                switch special {
                case .backspace: lineEdit = [0x15] // ^U
                case .left: lineEdit = [0x01]      // ^A
                case .right: lineEdit = [0x05]     // ^E
                default: lineEdit = nil
                }
                if let bytes = lineEdit {
                    wakeCursor()
                    snapToBottom()
                    clearSelection()
                    emit(bytes)
                    return
                }
            }
            // ⌘C / ⌘X copy the active selection (a read-only terminal can't truly cut, so ⌘X
            // behaves as copy), ⌘V pastes. These also work via the Edit menu's key equivalents
            // (which fire copy:/cut:/paste: on the first responder before keyDown); handling them
            // here keeps copy/paste working even without the menu.
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c", "x":
                // Copy/cut the selection; with no selection, let the app handle ⌘C/⌘X.
                // Anchor check, not the region getter — the getter can `emulatorSync`.
                if selectionAnchor != nil { copySelection(); return }
                super.keyDown(with: event)
                return
            case "v":
                paste(nil)
                return
            default:
                super.keyDown(with: event)
                return
            }
        }
        wakeCursor()
        // While an IME composition (preedit) is active, the input method owns every key:
        // Backspace edits the preedit, arrows/Space/Tab move or pick candidates, Return
        // commits, Escape cancels. Route the whole event through the input context — updated
        // or committed text comes back via setMarkedText / insertText — rather than letting
        // the special-key path below send Backspace, Return, etc. straight to the PTY (which
        // is why the composition couldn't be edited mid-typing).
        if hasMarkedText() {
            interpretKeyEvents([event])
            return
        }
        // Shift+PageUp/PageDown page through scrollback instead of going to the app.
        if event.modifierFlags.contains(.shift), let sk = Self.specialKey(for: event),
           sk == .pageUp || sk == .pageDown {
            scrollBy(lines: sk == .pageUp ? rows : -rows)
            return
        }
        // Any other key returns to the live bottom.
        snapToBottom()
        clearSelection()

        var mods: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        let modes = inputModes()
        // A held key auto-repeats; under Kitty "report event types" each repeat is tagged `:2`.
        let eventType: KeyEventType = event.isARepeat ? .repeat : .press

        if let special = Self.specialKey(for: event) {
            emit(inputEncoder.encode(special, modifiers: mods, event: eventType, modes: modes))
            return
        }

        // A composing Option is not a modifier for the text path: drop it so the input context
        // can deliver the layout's character (option+L → @ on German/Nordic layouts — #155;
        // dead keys included via the marked-text path), and so Kitty modes report the key
        // without a stale alt bit (kitty itself treats a composing Option the same way).
        // Special keys (above) keep Meta semantics in every mode — opt+arrow word motion is
        // macOS terminal convention — and Ctrl+Option combos never compose.
        mods = Self.effectiveTextModifiers(mods, mode: optionAsMeta, eventFlags: flags)

        // Control/Option — or Kitty "report all keys as escape codes" — take the encoder path:
        // Meta prefix + Control collapsing in legacy mode, full CSI-u (with alternate-key and
        // associated-text fields) under Kitty. Plain keys otherwise go through the input context so
        // dead keys and IME composition work — committed text arrives via `insertText`.
        let reportAllKeys = modes.kittyKeyboardFlags & 0b1000 != 0
        if mods.contains(.control) || mods.contains(.option) || reportAllKeys {
            let rawUnshifted = event.charactersIgnoringModifiers ?? ""
            let unshifted = ControlKeyNormalizer.normalizedKey(
                from: rawUnshifted,
                controlPressed: mods.contains(.control)
            )
            emit(inputEncoder.encode(
                text: unshifted,
                shifted: event.characters,
                modifiers: mods,
                event: eventType,
                associatedText: event.characters,
                modes: modes
            ))
            return
        }
        interpretKeyEvents([event])
    }

    public override func keyUp(with event: NSEvent) {
        // Terminals never report key release — except under the Kitty keyboard protocol's "report
        // event types" flag (0b10), which a program must explicitly enable. No-op otherwise.
        let modes = inputModes()
        guard modes.kittyKeyboardFlags & 0b10 != 0,
              copyMode == nil, !hasMarkedText(),
              !event.modifierFlags.contains(.command) else { return }

        var mods: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        if let special = Self.specialKey(for: event) {
            emit(inputEncoder.encode(special, modifiers: mods, event: .release, modes: modes))
            return
        }
        // Keep release events symmetric with the press: a composing Option was stripped from
        // the press encoding, so strip it here too.
        mods = Self.effectiveTextModifiers(mods, mode: optionAsMeta, eventFlags: flags)
        // Plain (text-producing) keys only have a release event when they're reported as escape
        // codes in the first place: Ctrl/Option-modified, or under "report all keys" (0b1000).
        let modified = mods.contains(.control) || mods.contains(.option)
        guard modified || modes.kittyKeyboardFlags & 0b1000 != 0 else { return }
        let unshifted = event.charactersIgnoringModifiers ?? ""
        guard !unshifted.isEmpty else { return }
        emit(inputEncoder.encode(
            text: unshifted, shifted: event.characters, modifiers: mods,
            event: .release, associatedText: nil, modes: modes
        ))
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onInput?(Data(bytes))
    }

    /// Strip a composing Option from the text-path modifier set: when the held Option side(s)
    /// compose characters (per `mode`), the key is plain text — not Meta, no Kitty alt bit.
    /// Control is never stripped (Ctrl+Option combos don't compose). `internal` so the
    /// modifier seam can be unit-tested.
    static func effectiveTextModifiers(
        _ mods: KeyModifiers, mode: OptionAsMetaMode, eventFlags: NSEvent.ModifierFlags
    ) -> KeyModifiers {
        var result = mods
        if result.contains(.option), !result.contains(.control),
           !optionActsAsMeta(mode, eventFlags: eventFlags) {
            result.remove(.option)
        }
        return result
    }

    /// Whether the held Option key(s) act as Meta for text keys. The side-split modes read the
    /// event's device-dependent modifier bits (NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK);
    /// an event without side bits (synthesized input, some assistive hardware) honors the
    /// user's Meta intent rather than silently composing. With both Options held, Meta wins
    /// when the meta-designated side is down.
    static func optionActsAsMeta(_ mode: OptionAsMetaMode, eventFlags: NSEvent.ModifierFlags) -> Bool {
        switch mode {
        case .meta: return true
        case .composed: return false
        case .leftMetaOnly, .rightMetaOnly:
            let left = eventFlags.rawValue & 0x0000_0020 != 0
            let right = eventFlags.rawValue & 0x0000_0040 != 0
            guard left || right else { return true }
            return mode == .leftMetaOnly ? left : right
        }
    }

    /// Map an NSEvent to a SpecialKey using the AppKit function-key unicode values.
    /// `internal` (not `private`) so the NSEvent→SpecialKey seam can be unit-tested.
    static func specialKey(for event: NSEvent) -> SpecialKey? {
        // Numeric-keypad keys (F30, DECKPAM): the character alone can't distinguish keypad
        // '7' from top-row '7', so key off `.numericPad` + the hardware keycode. Arrow keys
        // also carry `.numericPad`; the keycode table only claims true keypad codes and
        // everything else falls through to the character switch below. In numeric mode the
        // encoder emits the same plain byte the text path used to, so nothing changes until
        // a program enables application keypad (`ESC =`). Only the UNMODIFIED key is claimed
        // (Shift/NumLock aside): `keypadLegacy` ignores modifiers, so claiming Ctrl/Option
        // combos here would drop the control collapse / ESC meta prefix the text path applies
        // — modified keypad keys keep their pre-keypad byte output in both keypad modes.
        if event.modifierFlags.contains(.numericPad),
           event.modifierFlags.isDisjoint(with: [.control, .option, .command]),
           let keypad = keypadKey(forKeyCode: event.keyCode) {
            return keypad
        }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: return .up
        case NSDownArrowFunctionKey: return .down
        case NSLeftArrowFunctionKey: return .left
        case NSRightArrowFunctionKey: return .right
        case NSHomeFunctionKey: return .home
        case NSEndFunctionKey: return .end
        case NSPageUpFunctionKey: return .pageUp
        case NSPageDownFunctionKey: return .pageDown
        case NSInsertFunctionKey: return .insert
        case NSDeleteFunctionKey: return .deleteForward
        case NSF1FunctionKey: return .f1
        case NSF2FunctionKey: return .f2
        case NSF3FunctionKey: return .f3
        case NSF4FunctionKey: return .f4
        case NSF5FunctionKey: return .f5
        case NSF6FunctionKey: return .f6
        case NSF7FunctionKey: return .f7
        case NSF8FunctionKey: return .f8
        case NSF9FunctionKey: return .f9
        case NSF10FunctionKey: return .f10
        case NSF11FunctionKey: return .f11
        case NSF12FunctionKey: return .f12
        case NSF13FunctionKey: return .f13
        case NSF14FunctionKey: return .f14
        case NSF15FunctionKey: return .f15
        case NSF16FunctionKey: return .f16
        case NSF17FunctionKey: return .f17
        case NSF18FunctionKey: return .f18
        case NSF19FunctionKey: return .f19
        case NSF20FunctionKey: return .f20
        case NSMenuFunctionKey: return .menu
        case NSPauseFunctionKey: return .pause
        case NSPrintScreenFunctionKey: return .printScreen
        case NSScrollLockFunctionKey: return .scrollLock
        case 0x0D, 0x03: return .enter        // return, enter
        case 0x7F: return .backspace          // delete (backspace) key
        case 0x1B: return .escape
        case 0x09, 0x19: return .tab  // 0x19 = NSBackTabCharacter (Shift-Tab); encoder emits ESC[Z
        default: return nil
        }
    }

    /// ANSI keypad hardware keycodes (kVK_ANSI_Keypad*) → encoder keys.
    private static func keypadKey(forKeyCode keyCode: UInt16) -> SpecialKey? {
        switch keyCode {
        case 82: return .keypad0
        case 83: return .keypad1
        case 84: return .keypad2
        case 85: return .keypad3
        case 86: return .keypad4
        case 87: return .keypad5
        case 88: return .keypad6
        case 89: return .keypad7
        case 91: return .keypad8
        case 92: return .keypad9
        case 65: return .keypadDecimal
        case 75: return .keypadDivide
        case 67: return .keypadMultiply
        case 78: return .keypadMinus
        case 69: return .keypadPlus
        case 76: return .keypadEnter
        case 81: return .keypadEquals
        default: return nil
        }
    }

    // MARK: - Copy mode

    /// Enter copy mode, seeding the cursor at the live terminal cursor. The view's own
    /// emulator holds the scrollback, so no daemon text capture is needed.
    public func enterCopyMode() {
        guard copyMode == nil else { return }
        copyModeTables = KeybindingsStore.load()
        copyModeSearchEntry = nil
        copyMode = emulatorSync { emulator in
            let live = emulator.readGrid()
            let cursorLine = emulator.historyCount + live.cursor.row
            return CopyModeReducer.initialState(grid: emulator, cursorLine: cursorLine, cursorColumn: live.cursor.col)
        }
        scrollOffset = 0
        scrollFraction = 0 // copy mode is line-based; don't carry a smooth-scroll fraction in
        wheelLineRemainder = 0 // don't carry a sub-line wheel remainder across the mode boundary
        wheelColumnRemainder = 0
        notifyScrollChanged(historyCount: emulatorSync { $0.historyCount })
        scheduleRender()
    }

    /// Exit copy mode and return to the live bottom.
    public func exitCopyMode() {
        guard copyMode != nil else { return }
        copyMode = nil
        copyModeSearchEntry = nil
        scrollOffset = 0
        scrollFraction = 0
        wheelLineRemainder = 0
        wheelColumnRemainder = 0
        notifyScrollChanged(historyCount: emulatorSync { $0.historyCount })
        scheduleRender()
    }

    /// Run a copy-mode action from outside the view (the `:` prompt, `send-keys -X`,
    /// `copy-mode -X`). No-op when not in copy mode.
    public func performCopyModeAction(_ action: CopyModeAction) {
        guard copyMode != nil else { return }
        handleCopyModeAction(action)
    }

    private func handleCopyModeKey(_ event: NSEvent) {
        // A pending jump-to-char (`f`/`F`/`t`/`T`) consumes the very next keystroke as its target.
        if let kind = copyModeJumpEntry {
            copyModeJumpEntry = nil
            let chars = event.charactersIgnoringModifiers ?? ""
            if chars.unicodeScalars.first?.value != 0x1B, let ch = chars.first { // Escape cancels
                handleCopyModeAction(.jump(kind, String(ch)))
            } else {
                scheduleRender()
            }
            return
        }
        // Interactive search-query entry captures raw keys until Enter / Escape.
        if copyModeSearchEntry != nil {
            handleSearchEntryKey(event)
            return
        }
        guard let spec = Self.copyModeKeySpec(from: event),
              let table = copyModeTables?.table(KeyTableID.copyMode(modeKeys: copyModeKeys)),
              case let .copyModeCommand(action) = table.lookup(spec)?.command
        else { return } // unbound keys are swallowed (copy mode is modal)
        handleCopyModeAction(action)
    }

    private func handleCopyModeAction(_ action: CopyModeAction) {
        guard let state = copyMode else { return }
        let (next, effect) = emulatorSync { CopyModeReducer.reduce(state, action, grid: $0) }
        copyMode = next
        switch effect {
        case .none:
            scheduleRender()
        case let .copy(text):
            writeCopyModeSelection(text)
            scheduleRender()
        case let .copyAndCancel(text):
            writeCopyModeSelection(text)
            exitCopyMode()
        case let .pipe(text, command):
            copyModePipe(text: text, command: command)
            exitCopyMode()
        case .paste:
            exitCopyMode()
            paste(nil) // paste the most-recent buffer (mirrored to the system pasteboard on yank)
        case .cancel:
            exitCopyMode()
        case .beginSearchEntry:
            copyModeSearchEntry = ""
            scheduleRender()
        case let .beginJumpEntry(kind):
            copyModeJumpEntry = kind
            scheduleRender()
        }
    }

    private func handleSearchEntryKey(_ event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        let scalar = chars.unicodeScalars.first?.value ?? 0
        switch scalar {
        case 0x1B: // Escape — abandon the search
            copyModeSearchEntry = nil
            scheduleRender()
        case 0x0D, 0x03: // Enter — commit
            let query = copyModeSearchEntry ?? ""
            copyModeSearchEntry = nil
            if let state = copyMode, !query.isEmpty {
                copyMode = emulatorSync {
                    CopyModeReducer.applySearch(state, query: query, reverse: state.search.reverse, grid: $0)
                }
            }
            scheduleRender()
        case 0x7F, 0x08: // Backspace
            if var q = copyModeSearchEntry, !q.isEmpty { q.removeLast(); copyModeSearchEntry = q }
            scheduleRender()
        default:
            if scalar >= 0x20, !chars.isEmpty { copyModeSearchEntry = (copyModeSearchEntry ?? "") + chars }
            scheduleRender()
        }
    }

    private func writeCopyModeSelection(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onCopy?(text) // mirror into the daemon paste buffer
    }

    /// `copy-pipe`: feed the selected text to a shell command's stdin (detached), like tmux.
    private func copyModePipe(text: String, command: String) {
        guard !text.isEmpty, !command.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardInput = pipe
        // Don't let the child inherit the GUI app's stdout/stderr (it would leak app fds and
        // could block on a full inherited pipe); discard its output like tmux's copy-pipe.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Reap the child so it can't linger as a zombie across many copy-pipe invocations.
        process.terminationHandler = { _ in }
        guard (try? process.run()) != nil else { return }
        // Write off the main thread so a large selection into a slow/non-draining command can't
        // block the UI; a closed pipe (child already exited) throws and is ignored.
        let data = Data(text.utf8)
        let writer = pipe.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async {
            try? writer.write(contentsOf: data)
            try? writer.close()
        }
    }

    /// Convert an `NSEvent` to a `KeySpec` for copy-mode table lookup (mirrors the prefix
    /// keymap's mapping; kept local so the live-input path is untouched).
    private static func copyModeKeySpec(from event: NSEvent) -> KeySpec? {
        guard let chars = event.charactersIgnoringModifiers else { return nil }
        let key: String
        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            switch scalar.value {
            case 0x1B: key = "Escape"
            case 0x09, 0x19: key = "Tab"  // 0x19 = NSBackTabCharacter (Shift-Tab)
            case 0x0D, 0x03: key = "Enter"
            case 0x7F: key = "Backspace"
            case 0x20: key = "Space"
            case 0xF700: key = "Up"
            case 0xF701: key = "Down"
            case 0xF702: key = "Left"
            case 0xF703: key = "Right"
            case 0xF729: key = "Home"
            case 0xF72B: key = "End"
            case 0xF72C: key = "PageUp"
            case 0xF72D: key = "PageDown"
            default: key = chars
            }
        } else {
            key = chars
        }
        var modifiers: KeySpec.Modifiers = []
        let mask = event.modifierFlags
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.command) { modifiers.insert(.command) }
        if mask.contains(.shift), key.count > 1 { modifiers.insert(.shift) }
        return KeySpec(key: key, modifiers: modifiers)
    }

    /// Render copy mode: the grid at the model's scroll offset, with selection / search
    /// highlights and the copy-mode cursor, plus a status row. Returns false when not in
    /// copy mode so `renderNow` falls through to the normal path.
    private func renderCopyMode(renderer: TerminalMetalRenderer, drawable: CAMetalDrawable) -> Bool {
        guard let cm = copyMode else { return false }
        let emulator = emulatorState.emulator
        let offset = cm.scrollbackOffset(historyCount: emulator.historyCount)
        let grid = emulator.readGrid(scrollbackOffset: offset)
        let region: SelectionRegion? = cm.viewportSelection(rows: rows, columns: columns).map { vs in
            switch vs.kind {
            case .linear:
                return .linear(TerminalSelection((vs.startRow, vs.startColumn), (vs.endRow, vs.endColumn)))
            case .block:
                return .block(BlockSelection((vs.startRow, vs.startColumn), (vs.endRow, vs.endColumn)))
            }
        }
        let hits = cm.viewportSearchHits(rows: rows).map { m in
            TerminalSelection((m.line, m.startColumn), (m.line, max(m.startColumn, m.endColumn - 1)))
        }
        let reverseVideo = emulator.modes.reverseVideo
        let builder = reverseVideo ? frameBuildConfiguration.makeBuilder(reverseVideo: true) : frameBuilder
        let frameBuildStart = DispatchTime.now().uptimeNanoseconds
        var frame = builder.build(grid, region: region, searchHighlights: hits,
                                  copyModeCursor: cm.viewportCursor(rows: rows),
                                  imageProvider: { emulator.image(for: $0) })
        let frameBuildNanos = DispatchTime.now().uptimeNanoseconds &- frameBuildStart
        let statusText = copyModeSearchEntry.map { (cm.search.reverse ? "?" : "/") + $0 } ?? cm.statusLine()
        overlayCopyModeStatus(into: &frame, text: statusText)
        let didPresent = renderer.present(
            frame, to: drawable,
            clearColor: builder.renderColor(reverseVideo ? canvasForeground : canvasBackground, alpha: canvasOpacity),
            origin: (originOffsetX, originOffsetY), gamma: glyphGamma, ligatures: ligaturesEnabled,
            frameBuildNanos: frameBuildNanos,
            synchronizedWithTransaction: metalLayer.presentsWithTransaction
        )
        if didPresent { onRenderStats?(renderer.stats) }
        return true
    }

    /// Draw the copy-mode status into the bottom frame row (mode, position, match count, or
    /// the live search query) on an inverted band.
    private func overlayCopyModeStatus(into frame: inout TerminalFrame, text: String) {
        Self.applyCopyModeStatus(
            into: &frame,
            text: text,
            builder: frameBuilder,
            selectionBackground: selectionBackground,
            canvasForeground: canvasForeground,
            canvasBackground: canvasBackground
        )
    }

    nonisolated private static func applyCopyModeStatus(
        into frame: inout TerminalFrame,
        text: String,
        builder: FrameBuilder,
        selectionBackground: RGBColor?,
        canvasForeground: RGBColor,
        canvasBackground: RGBColor
    ) {
        let row = frame.rows - 1
        guard row >= 0, frame.columns > 0 else { return }
        let bandBg = builder.renderColor(selectionBackground ?? canvasForeground)
        let bandFg = builder.renderColor(canvasBackground)
        for col in 0 ..< frame.columns {
            let idx = row * frame.columns + col
            frame.cells[idx].codepoint = 0x20
            frame.cells[idx].foreground = bandFg
            frame.cells[idx].background = bandBg
            // The band is an opaque highlight, not the canvas color, so force its fill even
            // though the underlying cell may have been built as a skippable canvas cell.
            frame.cells[idx].drawBackground = true
            frame.cells[idx].underlineColor = bandFg
            frame.cells[idx].bold = false
            frame.cells[idx].italic = false
            frame.cells[idx].underline = .none
            frame.cells[idx].strikethrough = false
            frame.cells[idx].overline = false
            frame.cells[idx].width = .normal
            frame.cells[idx].combining0 = 0
            frame.cells[idx].combining1 = 0
        }
        // Write the status text one base scalar per column, folding combining marks onto their base
        // so a Thai search query renders correctly instead of exploding across the band.
        var col = 0
        var lastBaseIdx: Int? = nil
        for scalar in text.unicodeScalars {
            if CharacterWidth.width(of: scalar) == 0 {
                // Fold a true combining mark onto the base; drop non-extending format scalars.
                if scalar.properties.isGraphemeExtend, let bi = lastBaseIdx {
                    if frame.cells[bi].combining0 == 0 { frame.cells[bi].combining0 = scalar.value }
                    else if frame.cells[bi].combining1 == 0 { frame.cells[bi].combining1 = scalar.value }
                }
                continue
            }
            guard col < frame.columns else { break }
            let idx = row * frame.columns + col
            frame.cells[idx].codepoint = scalar.value
            lastBaseIdx = idx
            col += 1
        }
    }
}

// MARK: - NSTextInputClient (dead keys + IME)

extension HarnessTerminalSurfaceView: @preconcurrency NSTextInputClient {
    private func plainString(_ obj: Any) -> String {
        if let s = obj as? String { return s }
        if let a = obj as? NSAttributedString { return a.string }
        return ""
    }

    /// Committed text (plain typing, dead-key result, or finished IME composition).
    public func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let text = plainString(string)
        guard !text.isEmpty else { scheduleRender(); return }
        emit(inputEncoder.encode(text: text))
        scheduleRender()
    }

    /// In-progress composition shown as preedit over the grid.
    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = plainString(string)
        scheduleRender()
    }

    public func unmarkText() {
        markedText = ""
        scheduleRender()
    }

    public func hasMarkedText() -> Bool { !markedText.isEmpty }

    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: markedText.utf16.count)
    }

    public func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the IME candidate window should anchor: the cursor cell, in screen space.
    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let renderer, let window else { return .zero }
        let scale = window.backingScaleFactor
        let cellW = CGFloat(renderer.cellPixelWidth) / scale
        let cellH = CGFloat(renderer.cellPixelHeight) / scale
        let snapshot = emulatorSync { $0.readGrid() }
        let x = gridOriginPointsX + CGFloat(snapshot.cursor.col) * cellW
        // Convert grid-from-top to AppKit bottom-left origin.
        let yTop = gridOriginPointsY + CGFloat(snapshot.cursor.row) * cellH
        let viewRect = NSRect(x: x, y: bounds.height - yTop - cellH, width: cellW, height: cellH)
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Keys the input system classifies as commands (e.g. Return) are already handled in
    /// `keyDown` before reaching the IME, so swallow these silently (no system beep).
    public override func doCommand(by selector: Selector) {}
}
