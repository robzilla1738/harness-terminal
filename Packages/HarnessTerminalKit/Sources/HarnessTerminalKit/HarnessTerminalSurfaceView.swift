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
    var canvasOpacity: Float
    var colorRendering: TerminalColorRenderingMode
    var colorGamut: TerminalColorGamut
    var cursorStyle: CursorStyle
    var selectionBackground: RGBColor?
    var selectionForeground: RGBColor?
    var promptGutterEnabled: Bool

    func makeBuilder() -> FrameBuilder {
        FrameBuilder(
            resolver: resolver,
            cursorColor: cursorColor,
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
        sync { _ in lastPlainFrame = nil }
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
    /// Window/tab title (OSC 0 / OSC 2) — the host forwards this to its delegate.
    public var onTitle: ((String) -> Void)?
    /// Reported working directory (OSC 7) — the host forwards this to its delegate.
    public var onPwd: ((String) -> Void)?
    /// Terminal bell (BEL) — the host forwards this to its delegate.
    public var onBell: (() -> Void)?
    /// A shell command finished (OSC 133), with its run duration + exit code — the host forwards
    /// this for the long-running-command-finished notification.
    public var onCommandFinished: ((_ duration: TimeInterval, _ exitCode: Int?) -> Void)?
    /// Desktop notification requested by a program (OSC 9 → nil title; OSC 777 → title+body)
    /// — the host forwards this to its delegate.
    public var onDesktopNotification: ((_ title: String?, _ body: String) -> Void)?
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
    /// The (cols, rows) the live-resize preview was last built for, so a continuous drag rebuilds the
    /// re-wrap preview only when the cell count actually changes (sub-cell drag frames re-present the
    /// cached preview at the new drawable size). Reset on commit so the next drag starts fresh.
    private var previewCols = 0
    private var previewRows = 0
    /// In-flight `receiveOffMain` feed count: bumped on main before the emulator-queue dispatch,
    /// dropped on the queue once the parse completes. The live-resize preview reads `isBusy` to SKIP
    /// itself when the parser is busy — so a drag never blocks main on `emulatorState.sync` behind an
    /// in-flight parse (the cached-frame `repaintLastFrame` covers the frame instead). Lives in a
    /// `Sendable` lock-guarded box because it's touched from main AND the off-main emulator queue.
    private final class FeedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func enter() { lock.lock(); count += 1; lock.unlock() }
        func leave() { lock.lock(); count -= 1; lock.unlock() }
        var isBusy: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    }
    private let pendingFeed = FeedCounter()
    private var fontFamily: String
    private var fontSize: CGFloat
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
    /// First-responder state — the cursor only blinks while focused.
    private var focused = false
    /// Mouse selection endpoints (anchor = where the drag started, head = current). A
    /// `SelectionRegion` is derived from these (expanded by granularity) for highlight + extraction.
    private var selectionAnchor: (row: Int, column: Int)?
    private var selectionHead: (row: Int, column: Int)?
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
    /// Scrollback offset in lines (0 = live bottom; >0 = scrolled up into history).
    private var scrollOffset = 0
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
    private var trackingArea: NSTrackingArea?

    public init(
        themeName: String = ThemeManager.defaultThemeName,
        fontFamily: String = "Menlo",
        fontSize: CGFloat = 14,
        vivid: Bool = false,
        colorRendering: TerminalColorRenderingMode? = nil,
        colorGamut: TerminalColorGamut = .auto,
        offMainParserFramePipeline: Bool = true
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
            colorRendering: resolvedColorRendering,
            colorGamut: resolvedGamut
        )
        self.frameBuildConfiguration = SurfaceFrameBuildConfiguration(
            resolver: resolver,
            cursorColor: theme.cursor ?? theme.foreground,
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
        self.colorRendering = resolvedColorRendering
        self.colorGamut = resolvedGamut
        self.offMainParserFramePipelineEnabled = offMainParserFramePipeline
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
    public func receive(_ data: Data) {
        if offMainParserFramePipelineEnabled {
            receiveOffMain(data)
            return
        }
        let beforeHistory = emulatorState.emulator.historyCount
        emulatorState.emulator.feed(data)
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

    private func receiveOffMain(_ data: Data) {
        pendingFeed.enter() // mark parser busy so a concurrent drag preview skips (no main block)
        let pendingFeed = pendingFeed
        emulatorState.async { [weak self] emulator in
            let beforeHistory = emulator.historyCount
            emulator.feed(data)
            pendingFeed.leave()
            let afterHistory = emulator.historyCount
            let synchronized = emulator.modes.synchronizedOutput
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.testingMainHopCount &+= 1
                if self.scrollOffset > 0 {
                    let added = afterHistory - beforeHistory
                    if added > 0 { self.scrollOffset = min(afterHistory, self.scrollOffset + added) }
                }
                self.wakeCursor()
                if synchronized {
                    self.scheduler.setSynchronized(true)
                    self.armSyncTimeout()
                } else {
                    self.syncTimeout?.cancel(); self.syncTimeout = nil
                    self.scheduler.setSynchronized(false)
                    self.wakeDisplayLink()
                    // Low-latency echo (off-main): kick the frame build now rather than at the next
                    // tick. renderNowOffMain builds on the emulator queue and presents on main; the
                    // renderGeneration guard drops any stale build so there's no double present.
                    self.scheduler.presentNow()
                }
            }
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

    func testingReadGridSnapshot() -> TerminalGridSnapshot {
        emulatorSync { $0.readGrid() }
    }

    func testingWaitForEmulatorIdle() {
        emulatorState.sync { _ in }
    }

    func testingResizeGrid(cols: Int, rows: Int) {
        commitGridSize(cols: cols, rows: rows)
        emulatorState.sync { _ in } // commit now reflows off-main; flush so tests observe it synchronously
    }

    var testingRenderSynchronized: Bool { scheduler.synchronized }
    var testingRenderPending: Bool { scheduler.needsRender }

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
        canvasOpacity: Float,
        cursorStyle: String,
        cursorBlink: Bool,
        paddingX: CGFloat,
        paddingY: CGFloat,
        paddingBalance: Bool = true,
        selectionBackgroundHex: String?,
        selectionForegroundHex: String?,
        copyOnSelect: Bool,
        pasteProtection: Bool = true,
        scrollbackLines: Int,
        linearBlending: Bool,
        textRendering: TerminalTextRenderingMode? = nil,
        ligatures: Bool,
        minimumContrast: Double = 1,
        promptGutter: Bool = false,
        offMainParserFramePipeline: Bool = true
    ) {
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
        ligaturesEnabled = ligatures
        promptGutterEnabled = promptGutter
        let bg = RGBColor(hex: canvasBackgroundHex) ?? RGBColor(red: 0, green: 0, blue: 0)
        let fg = RGBColor(hex: canvasForegroundHex) ?? RGBColor(red: 255, green: 255, blue: 255)
        let cursor = RGBColor(hex: cursorHex) ?? fg
        // Selection background: explicit setting/theme value, else a neutral slate.
        let selBg = selectionBackgroundHex.flatMap { RGBColor(hex: $0) }
            ?? RGBColor(red: 68, green: 78, blue: 102)
        let selFg = selectionForegroundHex.flatMap { RGBColor(hex: $0) }
        // 16 ANSI colors for program output; nil slots fall back to the default palette.
        let palette: [RGBColor] = (0 ..< 16).map { i in
            let hex = (i < outputPaletteHex.count ? outputPaletteHex[i] : nil)
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
        colorProviderState.update(foreground: fg, background: bg, cursor: cursor, palette: palette)
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: palette),
            defaultForeground: fg,
            defaultBackground: bg,
            minimumContrast: minimumContrast
        )
        self.frameBuildConfiguration = SurfaceFrameBuildConfiguration(
            resolver: resolver,
            cursorColor: cursor,
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

    private func invalidateRenderGeneration() {
        renderGeneration &+= 1
        emulatorState.resetPlainFrame()
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
        emulator.onWorkingDirectoryChange = { [weak self] path in
            if Thread.isMainThread {
                self?.onPwd?(path)
            } else {
                DispatchQueue.main.async { [weak self] in self?.onPwd?(path) }
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
        renderer = TerminalMetalRenderer(device: device, fontFamily: fontFamily, fontSize: fontSize, scale: scale)
        // Tell the engine the real cell pixel size so inline-image cell footprints + cursor
        // advancement match what the renderer draws.
        if let renderer {
            emulatorSync { $0.setCellPixelSize(width: renderer.cellPixelWidth, height: renderer.cellPixelHeight) }
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
        if window != nil {
            StartupMetrics.shared.mark(.firstSurfaceAttached) // idempotent: first surface in a window
            buildRenderer() // pick up the real backing scale
            startDisplayLink()
            updateGridSize()
            restartBlinkTimer()
            scheduleRender()
            window?.makeFirstResponder(self)
        } else {
            // Removed from the window (pane closed / re-mounted): stop the blink timer so
            // it doesn't keep the run loop (and a dangling render) alive. The timer holds
            // `[weak self]`, so this is the teardown hook (no retain cycle either way).
            blinkTimer?.invalidate()
            blinkTimer = nil
            stopDisplayLink()
            invalidateRenderGeneration()
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
        scheduler.start()
    }

    private func stopDisplayLink() {
        renderLink?.invalidate()
        renderLink = nil
        scheduler.stop()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        buildRenderer()
        updateGridSize()
        scheduleRender()
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
        originOffsetX = Int((paddingPointsX * scale).rounded())
        originOffsetY = Int((paddingPointsY * scale).rounded())
        let usableWidth = max(1, pixelWidth - 2 * originOffsetX)
        let usableHeight = max(1, pixelHeight - 2 * originOffsetY)

        let newCols = max(1, usableWidth / renderer.cellPixelWidth)
        let newRows = max(1, usableHeight / renderer.cellPixelHeight)
        if paddingBalanced {
            // Center the grid: split the sub-cell remainder onto both sides instead of letting
            // `.topLeft` gravity park it all at the bottom-right. The renderer draws from this
            // origin and the leftover on every side reads as canvas; the odd pixel (integer / 2)
            // stays bottom-right and is invisible. Updated even when the cell count is unchanged
            // so a sub-cell resize re-centers on the next paint.
            originOffsetX += (usableWidth - newCols * renderer.cellPixelWidth) / 2
            originOffsetY += (usableHeight - newRows * renderer.cellPixelHeight) / 2
        }
        guard newCols != columns || newRows != rows else { return }
        if !hasSizedGrid {
            // First real layout: size immediately so the terminal opens correct (no flash).
            hasSizedGrid = true
            commitGridSize(cols: newCols, rows: newRows)
        } else {
            // Live HUD tick: the integer cols/rows only change at cell boundaries (the drawable
            // resizes smoothly every frame), so this fires exactly when the displayed size ticks.
            onGridSizeWillChange?(newCols, newRows, false)
            // Coalesce: the drawable already resized above (smooth); defer the authoritative
            // history-wide reflow + PTY SIGWINCH until the size settles so a sidebar slide / window
            // drag can't storm the shell. Each layout reschedules, so the commit fires once after
            // the last frame.
            scheduleResizeCommit(cols: newCols, rows: newRows)
            // Live re-wrap: show the *content re-wrapped* to the new width during the drag instead of
            // the old grid revealed/clipped — `previewViewportReflow` is O(visible) and non-mutating,
            // so it's affordable every cell-boundary tick. Rebuild only when the cell count changes;
            // `layout()` re-presents the cached preview at the smooth sub-cell drawable size.
            if newCols != previewCols || newRows != previewRows {
                previewCols = newCols
                previewRows = newRows
                updateResizePreview(cols: newCols, rows: newRows)
            }
        }
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
        guard cols != columns || newRows != rows else { return }
        columns = cols
        rows = newRows
        invalidateRenderGeneration()              // bump generation; drop stale preview / plain-frame cache
        onResize?(cols, newRows)                  // one PTY SIGWINCH (fire-and-forget)
        onGridSizeWillChange?(cols, newRows, true) // settled size for the HUD
        previewCols = 0; previewRows = 0           // force the next drag to rebuild a fresh preview
        if offMainParserFramePipelineEnabled {
            // Off-main pipeline: reflow on the emulator's serial queue (serialized with the output
            // feed), present the rebuilt frame on completion. Main never blocks on the O(history)
            // width reflow; the live preview / repaintLastFrame covers the interim.
            let generation = renderGeneration
            emulatorState.async { emulator in
                emulator.resize(cols: cols, rows: newRows)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.renderGeneration == generation else { return } // superseded by a newer resize
                    self.renderNowOffMain()
                }
            }
        } else {
            // Main-confined pipeline: the emulator lives on the main thread (no serial queue to
            // offload to), so resize + present synchronously — the pre-existing discipline. Going
            // off-main here would be an unsynchronized mutation of the main-confined emulator.
            emulatorSync { $0.resize(cols: cols, rows: newRows) }
            scheduler.forceRender()
        }
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

    private func renderNow() {
        if offMainParserFramePipelineEnabled {
            renderNowOffMain()
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
        let frameBuildStart = DispatchTime.now().uptimeNanoseconds
        var frame: TerminalFrame
        if plain {
            frame = frameBuilder.build(grid, region: nil,
                                       imageProvider: { emulator.image(for: $0) },
                                       reusing: lastPlainFrame, damage: damage)
        } else {
            frame = frameBuilder.build(grid, region: selectionRegion,
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
        frame.cursor.hollow = !focused
        // Clear to the canvas color at canvas opacity so any cell-rounding remainder reads
        // as the canvas (no seam, and translucent when opacity < 1). The grid draws at the
        // padding origin so the inset region shows the canvas.
        let didPresent = renderer.present(
            frame,
            to: drawable,
            clearColor: frameBuilder.renderColor(canvasBackground, alpha: canvasOpacity),
            origin: (originOffsetX, originOffsetY),
            gamma: glyphGamma,
            ligatures: ligaturesEnabled,
            damage: plain ? damage : nil,
            frameBuildNanos: frameBuildNanos
        )
        if didPresent { onRenderStats?(renderer.stats) }
        else { scheduleRender() } // transient encode/present failure — retry next tick
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
            renderNow()
        }
    }

    private func renderNowOffMain(synchronous: Bool = false) {
        guard renderer != nil else { return }
        let generation = renderGeneration
        let state = emulatorState
        let config = frameBuildConfiguration
        let requestedScrollOffset = scrollOffset
        let selectionRegion = currentSelectionRegion
        let preedit = markedText
        let blinkSetting = cursorBlinkEnabled
        let blinkVisible = cursorBlinkVisible
        let isFocused = focused
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
            let builder = config.makeBuilder()
            let frameBuildStart = DispatchTime.now().uptimeNanoseconds
            var frame: TerminalFrame
            var renderDamage: TerminalDamage?
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
            } else {
                let grid = requestedScrollOffset > 0
                    ? emulator.readGrid(scrollbackOffset: requestedScrollOffset)
                    : emulator.readGrid()
                let damage = emulator.consumeDamage()
                let findHits = findIsActive
                    ? Self.viewportFindHighlights(findMatchesSnapshot, scrollOffset: requestedScrollOffset, historyCount: emulator.historyCount, rows: viewRows)
                    : []
                let plain = requestedScrollOffset == 0 && selectionRegion == nil && preedit.isEmpty && findHits.isEmpty
                if plain {
                    // Only reuse a cached frame built for THIS generation — a stale-generation frame
                    // describes the old grid and would tear when diffed against fresh damage.
                    let reuse = state.lastPlainFrameGeneration == generation ? state.lastPlainFrame : nil
                    frame = builder.build(grid, region: nil,
                                          imageProvider: { emulator.image(for: $0) },
                                          reusing: reuse, damage: damage)
                    renderDamage = damage
                } else {
                    frame = builder.build(grid, region: selectionRegion,
                                          searchHighlights: findHits,
                                          imageProvider: { emulator.image(for: $0) })
                }
                if !preedit.isEmpty, requestedScrollOffset == 0 {
                    Self.applyPreedit(into: &frame, text: preedit, builder: builder, canvasForeground: fg)
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
                state.lastPlainFrame = plain ? frame : nil
                state.lastPlainFrameGeneration = generation
            }
            return SurfaceFrameBuildResult(
                generation: generation,
                frame: frame,
                damage: renderDamage,
                frameBuildNanos: DispatchTime.now().uptimeNanoseconds &- frameBuildStart,
                clearColor: builder.renderColor(bg, alpha: opacity)
            )
        }

        if synchronous {
            // Block until the worker builds this frame, then present inline (we're on main inside the
            // caller's CATransaction). `state.sync` queues behind any in-flight build, preserving order.
            let result = state.sync { build($0) }
            presentBuiltFrame(result)
        } else {
            let token = state.claimFrameToken()
            state.async { emulator in
                // Latest-wins coalescing: if a newer build is already queued behind this one, skip —
                // it will consume the damage this one would have (no rows lost), so a burst of marks
                // collapses to a single build instead of N stale frames.
                guard state.isLatestFrameToken(token) else { return }
                let result = build(emulator)
                DispatchQueue.main.async { [weak self] in self?.presentBuiltFrame(result) }
            }
        }
    }

    /// Present an already-built off-main frame (main thread). A stale generation / no window / no
    /// renderer is an intentional drop; a nil drawable or a failed present is transient, so re-arm the
    /// scheduler (and wake the link) to retry on the next tick rather than leaving a frame unshown.
    private func presentBuiltFrame(_ result: SurfaceFrameBuildResult) {
        guard renderGeneration == result.generation, window != nil, let renderer else { return }
        guard let drawable = metalLayer.nextDrawable() else { scheduleRender(); return }
        let didPresent = renderer.present(
            result.frame,
            to: drawable,
            clearColor: result.clearColor,
            origin: (originOffsetX, originOffsetY),
            gamma: glyphGamma,
            ligatures: ligaturesEnabled,
            damage: result.damage,
            frameBuildNanos: result.frameBuildNanos
        )
        if didPresent {
            // Remember the presented frame so a live resize can re-stretch it without rebuilding
            // (and without touching the emulator queue). See `repaintLastFrame`.
            lastPresentedResult = result
            onRenderStats?(renderer.stats)
        } else {
            scheduleRender() // transient encode/present failure — retry next tick
        }
        StartupMetrics.shared.mark(.firstDrawablePresented)
    }

    /// Re-present the last built frame at the *current* drawable size with no emulator-queue access
    /// — the smooth-resize fast path. Used by `layout()` during a live drag/animation: the grid
    /// hasn't reflowed yet (deferred to drag-end), so the cached frame is still the correct content;
    /// we just need to redraw it into the freshly-resized drawable. Returns false when there's no
    /// valid cached frame for this generation, so the caller falls back to a full synchronous build.
    ///
    /// `damage: nil` forces a full instance rebuild + redraw: the renderer always clears and draws
    /// the complete frame (loadAction `.clear`), but the per-row instance-upload cache is keyed to
    /// the old origin/viewport, so a full rebuild avoids reusing buffers built for the prior size.
    @discardableResult
    private func repaintLastFrame() -> Bool {
        guard let result = lastPresentedResult,
              result.generation == renderGeneration,
              window != nil, let renderer else { return false }
        guard let drawable = metalLayer.nextDrawable() else { return false }
        let didPresent = renderer.present(
            result.frame,
            to: drawable,
            clearColor: result.clearColor,
            origin: (originOffsetX, originOffsetY),
            gamma: glyphGamma,
            ligatures: ligaturesEnabled,
            damage: nil,
            frameBuildNanos: result.frameBuildNanos
        )
        if didPresent { onRenderStats?(renderer.stats) }
        return didPresent
    }

    /// Build a live re-wrap preview of the viewport at the current drag target `nc × nr` and stash it
    /// as `lastPresentedResult`, so `layout()`'s `repaintLastFrame` shows the content *re-wrapped to
    /// the new width* during the drag rather than the old grid revealed/clipped. Pure: reads the
    /// emulator via `previewViewportReflow` (O(visible), non-mutating) and never reflows history or
    /// sends `SIGWINCH` (both deferred to `commitGridSize`), so the shell's width belief never desyncs
    /// from the display. Skipped when an overlay the preview can't represent is active (scrollback,
    /// selection, IME pre-edit, find, copy mode) or on the alternate screen — `repaintLastFrame` then
    /// falls back to the cached frame. The emulator-queue read is cheap (~0.3 ms) and idle mid-drag.
    private func updateResizePreview(cols nc: Int, rows nr: Int) {
        // Only on the off-main pipeline (the emulator lives on its serial queue; when the flag is off
        // it is main-confined and `emulatorState.sync` would touch it off its confinement domain).
        // And ONLY when the parser is idle — otherwise the `emulatorState.sync` below would block
        // main behind an in-flight parse, the exact jank the cached-frame design eliminates; when
        // busy we skip and `repaintLastFrame` re-presents the cached frame instead.
        guard offMainParserFramePipelineEnabled, !pendingFeed.isBusy else { return }
        guard scrollOffset == 0, copyMode == nil, currentSelectionRegion == nil,
              markedText.isEmpty, !findActive else { return }
        let config = frameBuildConfiguration
        let bg = canvasBackground
        let opacity = canvasOpacity
        let isFocused = focused
        let generation = renderGeneration
        let result: SurfaceFrameBuildResult? = emulatorState.sync { emulator in
            guard let preview = emulator.previewViewportReflow(cols: nc, rows: nr) else { return nil }
            let builder = config.makeBuilder()
            var frame = builder.build(preview, region: nil, imageProvider: { emulator.image(for: $0) })
            frame.cursor.hollow = !isFocused
            return SurfaceFrameBuildResult(
                generation: generation, frame: frame, damage: nil,
                frameBuildNanos: 0, clearColor: builder.renderColor(bg, alpha: opacity)
            )
        }
        if let result { lastPresentedResult = result }
    }

    // MARK: - Cursor blink

    private func restartBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        cursorBlinkVisible = true
        guard cursorBlinkEnabled else { return }
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.focused else { return }
                self.cursorBlinkVisible.toggle()
                self.scheduleRender()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        blinkTimer = timer
    }

    /// Reset the cursor to solid after activity (typing/output), matching common terminals.
    private func wakeCursor() {
        guard cursorBlinkEnabled else { return }
        if !cursorBlinkVisible {
            cursorBlinkVisible = true
            scheduleRender()
        }
    }

    // MARK: - Scrollback

    /// Scroll the viewport by `lines` (positive = back into history). Clamped to the
    /// available history; clears any selection (its coordinates are viewport-relative).
    private func scrollBy(lines: Int) {
        let historyCount = emulatorSync { $0.historyCount }
        let target = max(0, min(historyCount, scrollOffset + lines))
        guard target != scrollOffset else { return }
        scrollOffset = target
        clearSelection()
        scheduleRender()
    }

    /// Jump back to the live bottom (e.g. on typing).
    private func snapToBottom() {
        guard scrollOffset != 0 else { return }
        scrollOffset = 0
        scheduleRender()
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

    /// Set the scrollback offset so virtual buffer line `index` is the top viewport row.
    private func scrollToBufferLine(_ index: Int) {
        let historyCount = emulatorSync { $0.historyCount }
        let target = max(0, min(historyCount, historyCount - index))
        guard target != scrollOffset else { return }
        scrollOffset = target
        clearSelection()
        scheduleRender()
    }

    // MARK: - Selection & copy

    /// The active selection region (nil when nothing is selected): rectangular for an Option-drag,
    /// else linear with the endpoints expanded by the current granularity (word / line).
    private var currentSelectionRegion: SelectionRegion? {
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        if selectionRectangular { return .block(BlockSelection((a.row, a.column), (h.row, h.column))) }
        guard selectionGranularity != .character else {
            return .linear(TerminalSelection((a.row, a.column), (h.row, h.column)))
        }
        // Order the endpoints, then expand the lower one to the start of its unit and the higher
        // one to the end of its unit (unioning when both are on the same row).
        let (lo, hi) = (a.row, a.column) <= (h.row, h.column) ? (a, h) : (h, a)
        let loRange = unitColumnRange(viewportRow: lo.row, column: lo.column)
        let hiRange = unitColumnRange(viewportRow: hi.row, column: hi.column)
        if lo.row == hi.row {
            return .linear(TerminalSelection((lo.row, min(loRange.lowerBound, hiRange.lowerBound)),
                                             (lo.row, max(loRange.upperBound, hiRange.upperBound))))
        }
        return .linear(TerminalSelection((lo.row, loRange.lowerBound), (hi.row, hiRange.upperBound)))
    }

    /// Columns spanned by the current granularity at a viewport cell: the whole row for `.line`,
    /// the whitespace-delimited word for `.word` (shared with copy mode), else the single column.
    private func unitColumnRange(viewportRow row: Int, column: Int) -> ClosedRange<Int> {
        switch selectionGranularity {
        case .character: return column ... column
        case .line: return 0 ... max(0, columns - 1)
        case .word:
            return emulatorSync { emu in
                let virtualLine = emu.historyCount - scrollOffset + row
                return emu.wordColumnRange(line: virtualLine, column: column)
            }
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
        let yFromTop = bounds.height - p.y - gridOriginPointsY
        let col = Int((x / cellW).rounded(.down))
        let row = Int((yFromTop / cellH).rounded(.down))
        return (max(0, min(rows - 1, row)), max(0, min(columns - 1, col)))
    }

    /// Mouse goes to the program when it enabled tracking — unless Shift is held, which
    /// always forces local selection (the standard terminal override).
    private func isMouseReporting(_ event: NSEvent) -> Bool {
        emulatorSync { $0.modes.mouseTrackingEnabled } && !event.modifierFlags.contains(.shift)
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
        let modes = emulatorSync { $0.modes }
        emit(inputEncoder.encodeMouse(
            button: button, kind: kind,
            column: pos.column, row: pos.row,
            modifiers: mouseModifiers(event), modes: modes
        ))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
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
        selectionAnchor = pos
        selectionHead = pos
        scheduleRender()
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
    /// surprising handler (e.g. a custom app scheme) on ⌘-click.
    private func openLink(_ string: String) {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "ftps", "file"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }

    public override func mouseDragged(with event: NSEvent) {
        if copyMode != nil { return }
        if isMouseReporting(event) {
            // Only report motion when the app asked for drag / any-motion tracking.
            let modes = emulatorSync { $0.modes }
            if modes.mouseDrag || modes.mouseAny {
                reportMouse(event, button: .left, kind: .drag)
            }
            return
        }
        guard selectionAnchor != nil, let pos = cell(at: event.locationInWindow) else { return }
        selectionHead = pos
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
        if isMouseReporting(event) { reportMouse(event, button: .middle, kind: .press) }
        else { super.otherMouseDown(with: event) }
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
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearLinkHover()
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
        let modes = emulatorSync { $0.modes }
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

    /// Run/refresh the search for `query` (incremental as the user types). Empty clears matches.
    public func updateFind(query: String) {
        findActive = true
        if query.isEmpty {
            findMatches = []
            findCurrentIndex = 0
        } else {
            findMatches = emulatorSync { emulator in
                TerminalBufferSearch.matches(query: query, lineCount: emulator.bufferLineCount) { emulator.bufferLine($0) }
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
            let steps = max(1, Int((abs(event.scrollingDeltaY) / cellH).rounded()))
            let action: CopyModeAction = event.scrollingDeltaY > 0 ? .cursorUp : .cursorDown
            for _ in 0 ..< steps { handleCopyModeAction(action) }
            return
        }
        if isMouseReporting(event) {
            let button: MouseButton = event.scrollingDeltaY > 0 ? .wheelUp : .wheelDown
            if event.scrollingDeltaY != 0 { reportMouse(event, button: button, kind: .press) }
            return
        }
        // Local scrollback: positive deltaY (content moves down) scrolls back into history.
        guard event.scrollingDeltaY != 0, let renderer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        let cellH = max(1, CGFloat(renderer.cellPixelHeight) / scale)
        let steps = max(1, Int((abs(event.scrollingDeltaY) / cellH).rounded()))
        scrollBy(lines: event.scrollingDeltaY > 0 ? steps : -steps)
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
        let bracketed = emulatorSync { $0.modes.bracketedPaste }
        if pasteProtection, !bracketed, Self.isUnsafePaste(normalized), let window {
            confirmPaste(normalized, in: window)
            return
        }
        deliverPaste(normalized)
    }

    private func deliverPaste(_ normalized: String) {
        snapToBottom()
        clearSelection()
        emit(inputEncoder.encodePaste(normalized, modes: emulatorSync { $0.modes }))
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
        selectionAnchor = (row: 0, column: 0)
        selectionHead = (row: rows - 1, column: columns - 1)
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
        guard let region = currentSelectionRegion else { return }
        let text = emulatorSync { emu -> String in
            let snapshot = scrollOffset > 0 ? emu.readGrid(scrollbackOffset: scrollOffset) : emu.readGrid()
            switch region {
            case let .linear(sel): return selectedText(sel, snapshot)
            case let .block(blk): return blockSelectedText(blk, snapshot)
            }
        }
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onCopy?(text)
    }

    /// Extract the selected text from the grid: per row, the in-range columns, skipping the
    /// trailing spacer of wide chars, with trailing whitespace trimmed and rows joined by \n.
    private func selectedText(_ sel: TerminalSelection, _ snapshot: TerminalGridSnapshot) -> String {
        var lines: [String] = []
        for row in sel.startRow ... sel.endRow {
            let startCol = (row == sel.startRow) ? sel.startColumn : 0
            let endCol = (row == sel.endRow) ? sel.endColumn : snapshot.cols - 1
            lines.append(rowText(row: row, startCol: startCol, endCol: endCol, snapshot: snapshot))
        }
        return lines.joined(separator: "\n")
    }

    /// Extract a rectangular (block) selection: the same column span on every row, rows joined by \n.
    private func blockSelectedText(_ blk: BlockSelection, _ snapshot: TerminalGridSnapshot) -> String {
        (blk.startRow ... blk.endRow)
            .map { rowText(row: $0, startCol: blk.startColumn, endCol: blk.endColumn, snapshot: snapshot) }
            .joined(separator: "\n")
    }

    /// One row's text over `[startCol, endCol]`: drop wide-char spacer tails, blanks → space,
    /// trailing whitespace trimmed.
    private func rowText(row: Int, startCol: Int, endCol: Int, snapshot: TerminalGridSnapshot) -> String {
        var line = ""
        var col = startCol
        while col <= endCol {
            let cell = snapshot.cell(row: row, col: col)
            if cell?.width == .spacerTail { col += 1; continue }
            if let codepoint = cell?.codepoint, codepoint != 0, let scalar = Unicode.Scalar(codepoint) {
                line.unicodeScalars.append(scalar)
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
    /// cursor at its end. Best-effort: one cell per scalar (wide composition may pack
    /// loosely until full-width preedit handling lands).
    private func overlayPreedit(into frame: inout TerminalFrame) {
        Self.applyPreedit(into: &frame, text: markedText, builder: frameBuilder, canvasForeground: canvasForeground)
    }

    nonisolated private static func applyPreedit(
        into frame: inout TerminalFrame,
        text: String,
        builder: FrameBuilder,
        canvasForeground: RGBColor
    ) {
        let row = frame.cursor.row
        guard row >= 0, row < frame.rows else { return }
        var col = frame.cursor.column
        let fg = builder.renderColor(canvasForeground)
        for scalar in text.unicodeScalars {
            let width = max(1, CharacterWidth.width(of: scalar))
            guard col >= 0, col + width <= frame.columns else { break }
            let idx = row * frame.columns + col
            guard idx >= 0, idx < frame.cells.count else { break }
            frame.cells[idx].codepoint = scalar.value
            frame.cells[idx].foreground = fg
            frame.cells[idx].underline = .single
            frame.cells[idx].width = (width == 2) ? .wide : .normal
            // Mark the trailing cell of a wide composing glyph as its spacer.
            if width == 2, idx + 1 < frame.cells.count {
                frame.cells[idx + 1].codepoint = 0
                frame.cells[idx + 1].width = .spacerTail
                frame.cells[idx + 1].underline = .single
            }
            col += width
        }
        frame.cursor.column = min(col, frame.columns - 1)
    }

    // MARK: - Input

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        focused = true
        cursorBlinkVisible = true
        scheduleRender()
        return true
    }

    public override func resignFirstResponder() -> Bool {
        focused = false
        // A modifier released while we're unfocused never reaches `flagsChanged`, so drop the
        // press-tracking state to keep Kitty modifier-key press/release reporting in sync on return.
        pressedModifierKeyCodes.removeAll()
        scheduleRender()
        return true
    }

    public override func keyDown(with event: NSEvent) {
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
                if currentSelectionRegion != nil { copySelection(); return }
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

        let modes = emulatorSync { $0.modes }
        // A held key auto-repeats; under Kitty "report event types" each repeat is tagged `:2`.
        let eventType: KeyEventType = event.isARepeat ? .repeat : .press

        if let special = Self.specialKey(for: event) {
            emit(inputEncoder.encode(special, modifiers: mods, event: eventType, modes: modes))
            return
        }

        // Control/Option — or Kitty "report all keys as escape codes" — take the encoder path:
        // Meta prefix + Control collapsing in legacy mode, full CSI-u (with alternate-key and
        // associated-text fields) under Kitty. Plain keys otherwise go through the input context so
        // dead keys and IME composition work — committed text arrives via `insertText`.
        let reportAllKeys = modes.kittyKeyboardFlags & 0b1000 != 0
        if mods.contains(.control) || mods.contains(.option) || reportAllKeys {
            let unshifted = event.charactersIgnoringModifiers ?? ""
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
        let modes = emulatorSync { $0.modes }
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

    /// Map an NSEvent to a SpecialKey using the AppKit function-key unicode values.
    /// `internal` (not `private`) so the NSEvent→SpecialKey seam can be unit-tested.
    static func specialKey(for event: NSEvent) -> SpecialKey? {
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
        scheduleRender()
    }

    /// Exit copy mode and return to the live bottom.
    public func exitCopyMode() {
        guard copyMode != nil else { return }
        copyMode = nil
        copyModeSearchEntry = nil
        scrollOffset = 0
        scheduleRender()
    }

    /// Run a copy-mode action from outside the view (the `:` prompt, `send-keys -X`,
    /// `copy-mode -X`). No-op when not in copy mode.
    public func performCopyModeAction(_ action: CopyModeAction) {
        guard copyMode != nil else { return }
        handleCopyModeAction(action)
    }

    private func handleCopyModeKey(_ event: NSEvent) {
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
        let frameBuildStart = DispatchTime.now().uptimeNanoseconds
        var frame = frameBuilder.build(grid, region: region, searchHighlights: hits,
                                       copyModeCursor: cm.viewportCursor(rows: rows),
                                       imageProvider: { emulator.image(for: $0) })
        let frameBuildNanos = DispatchTime.now().uptimeNanoseconds &- frameBuildStart
        let statusText = copyModeSearchEntry.map { (cm.search.reverse ? "?" : "/") + $0 } ?? cm.statusLine()
        overlayCopyModeStatus(into: &frame, text: statusText)
        let didPresent = renderer.present(
            frame, to: drawable,
            clearColor: frameBuilder.renderColor(canvasBackground, alpha: canvasOpacity),
            origin: (originOffsetX, originOffsetY), gamma: glyphGamma, ligatures: ligaturesEnabled,
            frameBuildNanos: frameBuildNanos
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
        }
        for (i, scalar) in text.unicodeScalars.enumerated() where i < frame.columns {
            frame.cells[row * frame.columns + i].codepoint = scalar.value
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
