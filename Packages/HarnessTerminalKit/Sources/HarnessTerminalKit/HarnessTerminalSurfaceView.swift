import AppKit
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
/// replacement for the libghostty `TerminalView` — bytes in via `receive(_:)`, input out
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
    /// Window padding in points (Ghostty `window-padding-x/y`); converted to device
    /// pixels and used both as the grid inset and the renderer's draw origin.
    private var paddingPointsX: CGFloat = 0
    private var paddingPointsY: CGFloat = 0
    /// Device-pixel grid origin (= padding × scale), reused by `renderNow` and (later)
    /// mouse→cell mapping.
    private var originOffsetX = 0
    private var originOffsetY = 0
    /// Cursor shape + blink (Ghostty `cursor-style` / `cursor-style-blink`).
    private var cursorStyle: CursorStyle = .block
    private var cursorBlinkEnabled = true
    /// Blink phase: false hides the cursor on the off-beat. Reset to true on activity.
    private var cursorBlinkVisible = true
    private var blinkTimer: Timer?
    /// First-responder state — the cursor only blinks while focused.
    private var focused = false

    private var columns: Int = 80
    private var rows: Int = 24
    private var renderScheduled = false

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
        emulator.feed(data)
        wakeCursor()
        scheduleRender()
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
        paddingY: CGFloat
    ) {
        let bg = RGBColor(hex: canvasBackgroundHex) ?? RGBColor(red: 0, green: 0, blue: 0)
        let fg = RGBColor(hex: canvasForegroundHex) ?? RGBColor(red: 255, green: 255, blue: 255)
        let cursor = RGBColor(hex: cursorHex) ?? fg
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
        self.canvasOpacity = max(0, min(1, canvasOpacity))
        self.cursorStyle = CursorStyle(rawValue: cursorStyle) ?? .block
        self.cursorBlinkEnabled = cursorBlink
        self.paddingPointsX = max(0, paddingX)
        self.paddingPointsY = max(0, paddingY)
        let resolver = CellColorResolver(
            palette: ANSIPalette(base16: palette),
            defaultForeground: fg,
            defaultBackground: bg
        )
        self.frameBuilder = FrameBuilder(
            resolver: resolver,
            cursorColor: cursor,
            canvasOpacity: self.canvasOpacity,
            cursorStyle: self.cursorStyle
        )
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
    }

    private func buildRenderer() {
        guard let device = metalLayer.device ?? MTLCreateSystemDefaultDevice() else { return }
        metalLayer.device = device
        let scale = window?.backingScaleFactor ?? 2.0
        renderer = TerminalMetalRenderer(device: device, fontFamily: fontFamily, fontSize: fontSize, scale: scale)
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
        updateGridSize()
        scheduleRender()
    }

    /// Recompute columns/rows from the view size and resize the emulator + drawable.
    private func updateGridSize() {
        guard let renderer else { return }
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let pixelWidth = max(1, Int(bounds.width * scale))
        let pixelHeight = max(1, Int(bounds.height * scale))
        metalLayer.drawableSize = CGSize(width: pixelWidth, height: pixelHeight)

        // Inset the grid by the window padding (in device pixels); the same offset is the
        // renderer's draw origin so the padding region shows the canvas color.
        originOffsetX = Int((paddingPointsX * scale).rounded())
        originOffsetY = Int((paddingPointsY * scale).rounded())
        let usableWidth = max(1, pixelWidth - 2 * originOffsetX)
        let usableHeight = max(1, pixelHeight - 2 * originOffsetY)

        let newCols = max(1, usableWidth / renderer.cellPixelWidth)
        let newRows = max(1, usableHeight / renderer.cellPixelHeight)
        if newCols != columns || newRows != rows {
            columns = newCols
            rows = newRows
            emulator.resize(cols: columns, rows: rows)
            onResize?(columns, rows)
        }
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
        var frame = frameBuilder.build(emulator.readGrid())
        // Cursor blink: hide on the off-beat (only while focused + blink enabled). A
        // program-hidden cursor (DECTCEM off) stays hidden regardless.
        if frame.cursor.visible, focused, cursorBlinkEnabled, !cursorBlinkVisible {
            frame.cursor.visible = false
        }
        // Clear to the canvas color at canvas opacity so any cell-rounding remainder reads
        // as the canvas (no seam, and translucent when opacity < 1). The grid draws at the
        // padding origin so the inset region shows the canvas.
        renderer.present(
            frame,
            to: drawable,
            clearColor: RenderColor(canvasBackground, alpha: canvasOpacity),
            origin: (originOffsetX, originOffsetY)
        )
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

    /// Reset the cursor to solid after activity (typing/output), matching Ghostty.
    private func wakeCursor() {
        guard cursorBlinkEnabled else { return }
        if !cursorBlinkVisible {
            cursorBlinkVisible = true
            scheduleRender()
        }
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
        // Let the app handle Command shortcuts (menus, palette, etc.).
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        wakeCursor()

        var mods: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }

        if let special = Self.specialKey(for: event) {
            emit(inputEncoder.encode(special, modifiers: mods, modes: emulator.modes))
            return
        }

        // Control/Option use the layout-independent characters; otherwise the composed
        // characters (handles shift, dead keys).
        let useIgnoring = mods.contains(.control) || mods.contains(.option)
        let text = (useIgnoring ? event.charactersIgnoringModifiers : event.characters) ?? ""
        emit(inputEncoder.encode(text: text, modifiers: mods))
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
}
