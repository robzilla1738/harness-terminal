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

/// The native, self-contained terminal surface: a `CAMetalLayer`-backed `NSView` that
/// drives a `TerminalEmulator` and draws it with `TerminalMetalRenderer`. This is the
/// replacement for the previous renderer's view — bytes in via `receive(_:)`, input out
/// via `onInput`, grid-size changes via `onResize`.
///
/// Scope (first on-screen cut): GPU rendering with the crisp-color pipeline (Display-P3 /
/// sRGB colorspace tagging), keyboard input, live resize, and PTY responses (DSR/DA).
/// Mouse reporting, selection, and scrollback are follow-ups.
@MainActor
public final class HarnessTerminalSurfaceView: NSView {
    /// Bytes the terminal produces for the PTY (typed input, key sequences, DSR/DA).
    public var onInput: ((Data) -> Void)?
    /// New grid size after a resize (columns, rows) — the host forwards this to the daemon.
    public var onResize: ((Int, Int) -> Void)?
    /// Window/tab title (OSC 0 / OSC 2) — the host forwards this to its delegate.
    public var onTitle: ((String) -> Void)?
    /// Reported working directory (OSC 7) — the host forwards this to its delegate.
    public var onPwd: ((String) -> Void)?
    /// Terminal bell (BEL) — the host forwards this to its delegate.
    public var onBell: (() -> Void)?
    /// Desktop notification requested by a program (OSC 9 → nil title; OSC 777 → title+body)
    /// — the host forwards this to its delegate.
    public var onDesktopNotification: ((_ title: String?, _ body: String) -> Void)?
    /// Copied selection text — the host mirrors it into the daemon paste buffer (the
    /// system pasteboard is written here directly).
    public var onCopy: ((String) -> Void)?
    /// Whether a program may set the system clipboard via OSC 52 (tmux
    /// `set-clipboard`). The host sets this from the option; default on.
    public var allowProgramClipboardAccess = true

    private let emulator: TerminalEmulator
    private let inputEncoder = InputEncoder()
    private let metalLayer = CAMetalLayer()
    private var renderer: TerminalMetalRenderer?

    private var frameBuilder: FrameBuilder
    private var vivid: Bool
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
    /// Device-pixel grid origin (= padding × scale), reused by `renderNow` and (later)
    /// mouse→cell mapping.
    private var originOffsetX = 0
    private var originOffsetY = 0
    /// Cursor shape + blink (`cursor-style` / `cursor-style-blink`).
    private var cursorStyle: CursorStyle = .block
    private var cursorBlinkEnabled = true
    /// Blink phase: false hides the cursor on the off-beat. Reset to true on activity.
    private var cursorBlinkVisible = true
    private var blinkTimer: Timer?
    /// First-responder state — the cursor only blinks while focused.
    private var focused = false
    /// Mouse selection endpoints (anchor = where the drag started, head = current). A
    /// `TerminalSelection` is derived from these for both highlight and text extraction.
    private var selectionAnchor: (row: Int, column: Int)?
    private var selectionHead: (row: Int, column: Int)?
    private var selectionBackground: RGBColor?
    private var selectionForeground: RGBColor?
    /// Copy the selection to the pasteboard automatically when a drag ends.
    private var copyOnSelect = false
    /// Scrollback offset in lines (0 = live bottom; >0 = scrolled up into history).
    private var scrollOffset = 0
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
    private var renderScheduled = false
    /// The last frame built on the plain live path (no scrollback/selection/copy-mode/IME), kept
    /// so the next plain render can reuse unchanged rows via the engine's dirty-row damage. Set to
    /// nil whenever a non-plain frame is drawn or the appearance changes, forcing a full rebuild.
    private var lastPlainFrame: TerminalFrame?
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

    public init(
        themeName: String = ThemeManager.defaultThemeName,
        fontFamily: String = "Menlo",
        fontSize: CGFloat = 14,
        vivid: Bool = false
    ) {
        let theme = HarnessThemeCatalog.theme(named: themeName)
            ?? HarnessThemeCatalog.theme(named: ThemeManager.defaultThemeName)!
        // Baseline appearance; the host immediately overrides via configureAppearance.
        self.frameBuilder = FrameBuilder(theme: theme)
        self.canvasBackground = theme.background
        self.canvasOpacity = 1
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.vivid = vivid
        self.emulator = TerminalEmulator(cols: columns, rows: rows)
        super.init(frame: .zero)
        configureLayer()
        configureEmulatorCallbacks()
        buildRenderer()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    // MARK: - Public API

    /// Feed PTY output bytes into the emulator and schedule a redraw.
    public func receive(_ data: Data) {
        let beforeHistory = emulator.historyCount
        emulator.feed(data)
        // If the user is scrolled up, stay anchored on the same content as new lines push
        // into history; at the bottom (offset 0) we naturally follow new output.
        if scrollOffset > 0 {
            let added = emulator.historyCount - beforeHistory
            if added > 0 { scrollOffset = min(emulator.historyCount, scrollOffset + added) }
        }
        wakeCursor()
        // DEC 2026 synchronized output: hold the last presented frame while the program is
        // mid-update (no tearing), and present atomically the moment it ends the batch — which
        // is exactly when this chunk leaves `synchronizedOutput` false. A timeout guards a
        // program that never closes the update.
        if emulator.modes.synchronizedOutput {
            armSyncTimeout()
        } else {
            syncTimeout?.cancel(); syncTimeout = nil
            scheduleRender()
        }
    }

    private func armSyncTimeout() {
        guard syncTimeout == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.syncTimeout = nil
            self?.scheduleRender() // force-present even if the program left 2026 set
        }
        syncTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + syncTimeoutInterval, execute: work)
    }

    public func receive(_ text: String) { receive(Data(text.utf8)) }

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
        canvasBackgroundHex: String,
        canvasForegroundHex: String,
        cursorHex: String,
        outputPaletteHex: [String?],
        canvasOpacity: Float,
        cursorStyle: String,
        cursorBlink: Bool,
        paddingX: CGFloat,
        paddingY: CGFloat,
        selectionBackgroundHex: String?,
        selectionForegroundHex: String?,
        copyOnSelect: Bool,
        scrollbackLines: Int,
        linearBlending: Bool,
        ligatures: Bool,
        promptGutter: Bool = false
    ) {
        emulator.maxScrollbackLines = scrollbackLines
        // Gamma-correct ("linear") blending thickens light-on-dark antialiasing slightly.
        glyphGamma = linearBlending ? 0.8 : 1.0
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
        self.vivid = vivid
        self.canvasBackground = bg
        self.canvasForeground = fg
        self.canvasCursor = cursor
        self.ansiPalette16 = palette
        self.canvasOpacity = max(0, min(1, canvasOpacity))
        self.cursorStyle = CursorStyle(rawValue: cursorStyle) ?? .block
        self.cursorBlinkEnabled = cursorBlink
        self.paddingPointsX = max(0, paddingX)
        self.paddingPointsY = max(0, paddingY)
        self.selectionBackground = selBg
        self.selectionForeground = selFg
        self.copyOnSelect = copyOnSelect
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: palette),
            defaultForeground: fg,
            defaultBackground: bg
        )
        self.frameBuilder = FrameBuilder(
            resolver: resolver,
            cursorColor: cursor,
            canvasOpacity: self.canvasOpacity,
            cursorStyle: self.cursorStyle,
            selectionBackground: selBg,
            selectionForeground: selFg,
            promptGutterEnabled: promptGutterEnabled
        )
        // Resolved colors/opacity changed — cached rows hold the old palette; force a full rebuild.
        lastPlainFrame = nil
        restartBlinkTimer()
        // Opaque only when fully opaque; otherwise the layer must be non-opaque so the
        // window-wide blur shows through the translucent canvas.
        metalLayer.isOpaque = self.canvasOpacity >= 1
        metalLayer.colorspace = CGColorSpace(name: vivid ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
        buildRenderer()
        updateGridSize()
        scheduleRender()
    }

    // MARK: - Setup

    private func configureLayer() {
        // Layer-hosting: assign the custom layer before enabling wantsLayer.
        layer = metalLayer
        wantsLayer = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = TerminalMetalRenderer.pixelFormat
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        // Pin the grid to the top-left so any sub-cell remainder from flooring rows/cols
        // parks at the bottom-right instead of being centered into a hairline seam at the
        // top edge during live resize.
        metalLayer.contentsGravity = .topLeft
        // Tag the layer colorspace so wide-gamut output isn't clamped — the crisp-color
        // contract (Display-P3 when vivid, sRGB otherwise).
        metalLayer.colorspace = CGColorSpace(name: vivid ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
    }

    private func configureEmulatorCallbacks() {
        emulator.onResponse = { [weak self] data in
            self?.onInput?(data)
        }
        emulator.onTitleChange = { [weak self] title in
            self?.onTitle?(title)
        }
        emulator.onWorkingDirectoryChange = { [weak self] path in
            self?.onPwd?(path)
        }
        emulator.onBell = { [weak self] in
            self?.onBell?()
        }
        emulator.onNotification = { [weak self] title, body in
            self?.onDesktopNotification?(title, body)
        }
        emulator.onPointerShapeChange = { [weak self] shape in
            self?.applyPointerShape(shape)
        }
        emulator.onSetClipboard = { [weak self] text in
            guard let self, self.allowProgramClipboardAccess, !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self.onCopy?(text)   // mirror into the daemon paste buffer, like a yank
        }
        // Answer OSC 10/11/12/4 color queries from the resolved theme (light/dark detection).
        emulator.colorProvider = { [weak self] role in
            guard let self else { return nil }
            let c: RGBColor
            switch role {
            case .foreground: c = self.canvasForeground
            case .background: c = self.canvasBackground
            case .cursor: c = self.canvasCursor
            case let .palette(i):
                guard i >= 0, i < self.ansiPalette16.count else { return nil }
                c = self.ansiPalette16[i]
            }
            return (c.red, c.green, c.blue)
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
            emulator.setCellPixelSize(width: renderer.cellPixelWidth, height: renderer.cellPixelHeight)
        }
    }

    // MARK: - Layout & rendering

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            buildRenderer() // pick up the real backing scale
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
        }
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
        // resize never shows a stale frame stretched to the new bounds (the flicker). Drawing
        // synchronously here (not via the async `scheduleRender`) closes the gap where the
        // drawable has the new size but the old grid is still presented.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGridSize()
        renderNow()
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
        guard newCols != columns || newRows != rows else { return }
        if !hasSizedGrid {
            // First real layout: size immediately so the terminal opens correct (no flash).
            hasSizedGrid = true
            commitGridSize(cols: newCols, rows: newRows)
        } else {
            // Coalesce: the drawable already resized above (smooth); defer the grid reflow + PTY
            // SIGWINCH until the size settles so a sidebar slide / window drag can't storm the
            // shell. Each layout reschedules, so the commit fires once after the last frame.
            scheduleResizeCommit(cols: newCols, rows: newRows)
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

    /// Commit the settled size to the emulator grid (reflow) and the PTY (one SIGWINCH),
    /// keeping the two in lockstep, then repaint.
    private func commitGridSize(cols: Int, rows newRows: Int) {
        resizeCommitWork = nil
        guard cols != columns || newRows != rows else { return }
        columns = cols
        rows = newRows
        emulator.resize(cols: cols, rows: newRows)
        onResize?(cols, newRows)
        renderNow()
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderScheduled = false
            self?.renderNow()
        }
    }

    private func renderNow() {
        guard let renderer, let drawable = metalLayer.nextDrawable() else { return }
        // Copy mode owns the whole surface while active (its own scroll offset + overlay).
        if renderCopyMode(renderer: renderer, drawable: drawable) { lastPlainFrame = nil; return }
        let grid = scrollOffset > 0 ? emulator.readGrid(scrollbackOffset: scrollOffset) : emulator.readGrid()
        // Consume dirty-row damage every frame to keep the engine's "since last render" window
        // aligned, then feed it to the builder only on the plain live path. Scrollback, an active
        // selection, and IME preedit all rebuild every row (they aren't tracked by damage), so
        // they take the full path and reset the reuse cache.
        let damage = emulator.consumeDamage()
        let plain = scrollOffset == 0 && currentSelection == nil && markedText.isEmpty
        var frame: TerminalFrame
        if plain {
            frame = frameBuilder.build(grid, region: nil,
                                       imageProvider: { [weak self] in self?.emulator.image(for: $0) },
                                       reusing: lastPlainFrame, damage: damage)
        } else {
            frame = frameBuilder.build(grid, selection: currentSelection,
                                       imageProvider: { [weak self] in self?.emulator.image(for: $0) })
        }
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
        // Clear to the canvas color at canvas opacity so any cell-rounding remainder reads
        // as the canvas (no seam, and translucent when opacity < 1). The grid draws at the
        // padding origin so the inset region shows the canvas.
        renderer.present(
            frame,
            to: drawable,
            clearColor: RenderColor(canvasBackground, alpha: canvasOpacity),
            origin: (originOffsetX, originOffsetY),
            gamma: glyphGamma,
            ligatures: ligaturesEnabled
        )
        // Retain only a plain frame for row reuse; a selection/scrollback/preedit frame would
        // poison the cache with overlay-baked cells, so drop it. (`plain` already excludes IME.)
        lastPlainFrame = plain ? frame : nil
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
        let target = max(0, min(emulator.historyCount, scrollOffset + lines))
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
        let prompts = emulator.promptRows
        guard !prompts.isEmpty else { return }
        let topVisible = emulator.historyCount - scrollOffset   // buffer index of the top row
        guard let target = prompts.last(where: { $0 < topVisible }) else { return }
        scrollToBufferLine(target)
    }

    /// Scroll so the nearest shell-prompt row *below* the current top-of-viewport line sits at the
    /// top. No-op without marks or when already at/after the last prompt.
    public func jumpToNextPrompt() {
        let prompts = emulator.promptRows
        guard !prompts.isEmpty else { return }
        let topVisible = emulator.historyCount - scrollOffset
        guard let target = prompts.first(where: { $0 > topVisible }) else { return }
        scrollToBufferLine(target)
    }

    /// Set the scrollback offset so virtual buffer line `index` is the top viewport row.
    private func scrollToBufferLine(_ index: Int) {
        let target = max(0, min(emulator.historyCount, emulator.historyCount - index))
        guard target != scrollOffset else { return }
        scrollOffset = target
        clearSelection()
        scheduleRender()
    }

    // MARK: - Selection & copy

    /// The active selection span (nil when nothing is selected).
    private var currentSelection: TerminalSelection? {
        guard let a = selectionAnchor, let h = selectionHead else { return nil }
        return TerminalSelection((a.row, a.column), (h.row, h.column))
    }

    private func clearSelection() {
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
        let x = p.x - paddingPointsX
        let yFromTop = bounds.height - p.y - paddingPointsY
        let col = Int((x / cellW).rounded(.down))
        let row = Int((yFromTop / cellH).rounded(.down))
        return (max(0, min(rows - 1, row)), max(0, min(columns - 1, col)))
    }

    /// Mouse goes to the program when it enabled tracking — unless Shift is held, which
    /// always forces local selection (the standard terminal override).
    private func isMouseReporting(_ event: NSEvent) -> Bool {
        emulator.modes.mouseTrackingEnabled && !event.modifierFlags.contains(.shift)
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
        emit(inputEncoder.encodeMouse(
            button: button, kind: kind,
            column: pos.column, row: pos.row,
            modifiers: mouseModifiers(event), modes: emulator.modes
        ))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if copyMode != nil { return } // copy mode is keyboard-driven; ignore clicks
        // ⌘-click opens an OSC 8 hyperlink or an auto-detected URL (like Ghostty/Terminal.app).
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
        selectionAnchor = pos
        selectionHead = pos
        scheduleRender()
    }

    /// The clickable URL at a grid cell: an OSC 8 hyperlink first, else an auto-detected URL in
    /// the row text. The row is built one character per cell so `column` maps directly.
    private func linkURL(atRow row: Int, column col: Int) -> String? {
        let grid = scrollOffset > 0 ? emulator.readGrid(scrollbackOffset: scrollOffset) : emulator.readGrid()
        guard row >= 0, row < grid.rows, col >= 0, col < grid.cols else { return nil }
        if let cell = grid.cell(row: row, col: col), cell.hyperlinkID != 0,
           let url = emulator.hyperlinkURL(id: cell.hyperlinkID) {
            return url
        }
        var line = ""
        line.reserveCapacity(grid.cols)
        for c in 0 ..< grid.cols {
            guard let cell = grid.cell(row: row, col: c), cell.width != .spacerTail else { line.append(" "); continue }
            line.unicodeScalars.append(cell.codepoint == 0 ? " " : (Unicode.Scalar(cell.codepoint) ?? " "))
        }
        return URLDetection.url(in: line, at: col)
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
            if emulator.modes.mouseDrag || emulator.modes.mouseAny {
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
        // A click with no drag clears the selection; a real drag optionally copies.
        if let a = selectionAnchor, let h = selectionHead, a == h {
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

    public override func scrollWheel(with event: NSEvent) {
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
    @objc public func paste(_ sender: Any?) {
        guard let raw = NSPasteboard.general.string(forType: .string), !raw.isEmpty else { return }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        snapToBottom()
        clearSelection()
        emit(inputEncoder.encodePaste(normalized, modes: emulator.modes))
    }

    /// Select the entire visible viewport (Edit ▸ Select All / ⌘A).
    @objc public override func selectAll(_ sender: Any?) {
        guard rows > 0, columns > 0 else { return }
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
        guard let sel = currentSelection else { return }
        let text = selectedText(sel, emulator.readGrid())
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
            var line = ""
            var col = startCol
            while col <= endCol {
                let cell = snapshot.cell(row: row, col: col)
                if cell?.width == .spacerTail {
                    col += 1
                    continue
                }
                if let codepoint = cell?.codepoint, codepoint != 0, let scalar = Unicode.Scalar(codepoint) {
                    line.unicodeScalars.append(scalar)
                } else {
                    line += " "
                }
                col += 1
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - IME preedit

    /// Draw the marked (composing) text over the grid starting at the cursor, and park the
    /// cursor at its end. Best-effort: one cell per scalar (wide composition may pack
    /// loosely until full-width preedit handling lands).
    private func overlayPreedit(into frame: inout TerminalFrame) {
        let row = frame.cursor.row
        guard row >= 0, row < frame.rows else { return }
        var col = frame.cursor.column
        let fg = RenderColor(canvasForeground)
        for scalar in markedText.unicodeScalars {
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
            // app), matching Terminal.app/Ghostty: ⌘⌫ = delete to line start (^U), ⌘← / ⌘→ =
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
                if currentSelection != nil { copySelection(); return }
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

        if let special = Self.specialKey(for: event) {
            emit(inputEncoder.encode(special, modifiers: mods, modes: emulator.modes))
            return
        }

        // Control/Option take the raw path (Meta prefix + control collapsing). Plain keys
        // go through the input context so dead keys and IME composition work — committed
        // text arrives via `insertText`, composition via `setMarkedText`.
        if mods.contains(.control) || mods.contains(.option) {
            let text = event.charactersIgnoringModifiers ?? ""
            emit(inputEncoder.encode(text: text, modifiers: mods, modes: emulator.modes))
            return
        }
        interpretKeyEvents([event])
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        onInput?(Data(bytes))
    }

    /// Map an NSEvent to a SpecialKey using the AppKit function-key unicode values.
    private static func specialKey(for event: NSEvent) -> SpecialKey? {
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
        case 0x0D, 0x03: return .enter        // return, enter
        case 0x7F: return .backspace          // delete (backspace) key
        case 0x1B: return .escape
        case 0x09: return .tab
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
        let live = emulator.readGrid()
        let cursorLine = emulator.historyCount + live.cursor.row
        copyMode = CopyModeReducer.initialState(grid: emulator, cursorLine: cursorLine, cursorColumn: live.cursor.col)
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
        let (next, effect) = CopyModeReducer.reduce(state, action, grid: emulator)
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
                copyMode = CopyModeReducer.applySearch(state, query: query, reverse: state.search.reverse, grid: emulator)
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
            case 0x09: key = "Tab"
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
        var frame = frameBuilder.build(grid, region: region, searchHighlights: hits,
                                       copyModeCursor: cm.viewportCursor(rows: rows),
                                       imageProvider: { [weak self] in self?.emulator.image(for: $0) })
        let statusText = copyModeSearchEntry.map { (cm.search.reverse ? "?" : "/") + $0 } ?? cm.statusLine()
        overlayCopyModeStatus(into: &frame, text: statusText)
        renderer.present(
            frame, to: drawable,
            clearColor: RenderColor(canvasBackground, alpha: canvasOpacity),
            origin: (originOffsetX, originOffsetY), gamma: glyphGamma, ligatures: ligaturesEnabled
        )
        return true
    }

    /// Draw the copy-mode status into the bottom frame row (mode, position, match count, or
    /// the live search query) on an inverted band.
    private func overlayCopyModeStatus(into frame: inout TerminalFrame, text: String) {
        let row = frame.rows - 1
        guard row >= 0, frame.columns > 0 else { return }
        let bandBg = RenderColor(selectionBackground ?? canvasForeground)
        let bandFg = RenderColor(canvasBackground)
        for col in 0 ..< frame.columns {
            let idx = row * frame.columns + col
            frame.cells[idx].codepoint = 0x20
            frame.cells[idx].foreground = bandFg
            frame.cells[idx].background = bandBg
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
        let snapshot = emulator.readGrid()
        let x = paddingPointsX + CGFloat(snapshot.cursor.col) * cellW
        // Convert grid-from-top to AppKit bottom-left origin.
        let yTop = paddingPointsY + CGFloat(snapshot.cursor.row) * cellH
        let viewRect = NSRect(x: x, y: bounds.height - yTop - cellH, width: cellW, height: cellH)
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    public func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Keys the input system classifies as commands (e.g. Return) are already handled in
    /// `keyDown` before reaching the IME, so swallow these silently (no system beep).
    public override func doCommand(by selector: Selector) {}
}
