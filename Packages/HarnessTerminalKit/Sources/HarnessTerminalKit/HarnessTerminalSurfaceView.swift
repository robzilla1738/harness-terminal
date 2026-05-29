import AppKit
import HarnessTerminalEngine
import HarnessTerminalRenderer
import HarnessTheme
import Metal
import QuartzCore

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

    private let emulator: TerminalEmulator
    private let inputEncoder = InputEncoder()
    private let metalLayer = CAMetalLayer()
    private var renderer: TerminalMetalRenderer?

    private var theme: HarnessThemeDefinition
    private var frameBuilder: FrameBuilder
    private var vivid: Bool
    private var fontFamily: String
    private var fontSize: CGFloat

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
        self.theme = theme
        self.frameBuilder = FrameBuilder(theme: theme)
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
        scheduleRender()
    }

    public func receive(_ text: String) { receive(Data(text.utf8)) }

    /// Re-theme live (theme picker / settings change).
    public func applyTheme(named name: String) {
        guard let theme = HarnessThemeCatalog.theme(named: name) else { return }
        self.theme = theme
        self.frameBuilder = FrameBuilder(theme: theme)
        scheduleRender()
    }

    /// Switch font / colorspace (settings change) — rebuilds the renderer + atlas.
    public func applyAppearance(fontFamily: String, fontSize: CGFloat, vivid: Bool) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.vivid = vivid
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
        // Tag the layer colorspace so wide-gamut output isn't clamped — the crisp-color
        // contract (Display-P3 when vivid, sRGB otherwise).
        metalLayer.colorspace = CGColorSpace(name: vivid ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
    }

    private func configureEmulatorCallbacks() {
        emulator.onResponse = { [weak self] data in
            self?.onInput?(data)
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
            scheduleRender()
            window?.makeFirstResponder(self)
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

        let newCols = max(1, pixelWidth / renderer.cellPixelWidth)
        let newRows = max(1, pixelHeight / renderer.cellPixelHeight)
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
        let frame = frameBuilder.build(emulator.readGrid())
        renderer.present(frame, to: drawable, clearColor: RenderColor(theme.background))
    }

    // MARK: - Input

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Let the app handle Command shortcuts (menus, palette, etc.).
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

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
