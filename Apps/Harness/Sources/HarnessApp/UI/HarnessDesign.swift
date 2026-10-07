import AppKit
import HarnessCore
import QuartzCore

/// Layout metrics and chrome helpers; colors come from `HarnessChrome.current`.
@MainActor
enum HarnessDesign {
    /// The transparent brand mark (`HarnessLogo.png`, bundled into the app) for hero tiles in
    /// onboarding + the About panel. Falls back to the (opaque) app icon if absent.
    static func brandLogo() -> NSImage? {
        if let url = Bundle.main.url(forResource: "HarnessLogo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }

    static let sidebarWidth: CGFloat = 264
    /// Distance from the window top to the traffic lights' center, measured from the real
    /// window when it's built (`MainWindowController`). The tab row and the sidebar's top
    /// controls center on this line so they sit level with the lights.
    static var titleRowCenter: CGFloat = 26
    /// Tall enough to center the tabs on the lights and leave the same gap to the card
    /// below as every other card edge (`ChromeLayout.islandGap`; the card insets half).
    static var tabBarHeight: CGFloat {
        titleRowCenter + tabPillHeight / 2 + CGFloat(ChromeLayout.islandGap / 2)
    }
    /// One size for every icon on the tab row, including the sidebar bell.
    static let chromeIconPointSize: CGFloat = 14
    static let chromeIconButtonSize: CGFloat = 28
    static let workspaceBarHeight: CGFloat = 42
    static let sessionRowHeight: CGFloat = 58
    static let footerHeight: CGFloat = 40
    static let tabPillHeight: CGFloat = 30
    /// Leading app tile in sidebar rows.
    static let iconTileSize: CGFloat = 20
    /// The tab's app tile is smaller than the pill by the same margin on every side, so it
    /// sits in the capsule's rounded end with even space above, below, and before it.
    static let tabIconTileSize: CGFloat = 18
    static var tabIconTileInset: CGFloat { (tabPillHeight - tabIconTileSize) / 2 }
    static let sidebarTabRowHeight: CGFloat = 34
    static let sidebarSessionHeaderHeight: CGFloat = 30
    /// Leading space the traffic lights take on a full-size-content window's top row.
    static let trafficLightClearance: CGFloat = 76
    static let paneHeaderHeight: CGFloat = 30
    static let paneHeaderButtonSize: CGFloat = 24

    static let horizontalInset: CGFloat = Spacing.lg
    static let rowSpacing: CGFloat = Spacing.xxs

    static var chrome: HarnessChromePalette { HarnessChrome.current }

    // MARK: - Design tokens
    //
    // Single source of truth for spacing, radius, motion, and typography. New code
    // should reference these rather than literals; existing call sites migrate to
    // them as each file is touched. Every token equals the value it replaced, so
    // adopting a token is a behavior-neutral change.

    /// Spacing scale in points. Prefer these over literals so density stays uniform.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 22
    }

    /// Corner-radius vocabulary, smallest to largest. Pair every use with
    /// `.cornerCurve = .continuous`. No literal radii in UI code.
    enum Radius {
        static let hairline: CGFloat = 3
        static let badge: CGFloat = 4
        static let pill: CGFloat = 5
        static let control: CGFloat = 6
        static let card: CGFloat = 8
        /// Terminal islands, toasts, and popovers.
        static let overlay: CGFloat = 10
        static let panel: CGFloat = 14
        static let capsule: CGFloat = 999
    }

    /// Animation durations (seconds) and shared easing curves. Keep motion short.
    enum Motion {
        static let microFast: TimeInterval = 0.10
        static let fast: TimeInterval = 0.16
        static let standard: TimeInterval = 0.22
        static let slow: TimeInterval = 0.32

        static var entrance: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
        static var exit: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeIn) }
        static var standardEase: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeInEaseOut) }
        /// Slightly overshoot-free spring feel, used for entrance pops (palette, prefix indicator).
        static var spring: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.1) }
    }

    /// Semantic fonts so sizes/weights live in one place.
    enum Typography {
        /// The one font every primary chrome label uses — workspace name, search
        /// field, session titles, tab titles, switcher rows, the Settings row. Keeping
        /// these identical (size + weight) is what makes the sidebar and tab strip read
        /// as one consistent surface instead of a mix of sizes/weights.
        static var sidebarLabel: NSFont { .systemFont(ofSize: 13, weight: .medium) }
        static var rowTitle: NSFont { sidebarLabel }
        static var rowMeta: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }
        static var tabTitle: NSFont { sidebarLabel }
        static var paneHeader: NSFont { sidebarLabel }
        static var sectionLabel: NSFont { .systemFont(ofSize: 10.5, weight: .semibold) }
        static var badge: NSFont { .monospacedSystemFont(ofSize: 10.5, weight: .semibold) }
        static var kbd: NSFont { .monospacedSystemFont(ofSize: 12, weight: .semibold) }
        static var paletteTitle: NSFont { .systemFont(ofSize: 13.5, weight: .medium) }
        static var paletteHeader: NSFont { .systemFont(ofSize: 10, weight: .heavy) }
        static var settingsHeading: NSFont { .systemFont(ofSize: 11, weight: .semibold) }
    }

    /// Drop-shadow recipe presets. Apply with `applyShadow(.elevation1, to: layer)`.
    enum Shadow {
        case none
        /// Subtle resting elevation (cards, pills).
        case elevation1
        /// Hover/active elevation.
        case elevation2
        /// Floating overlays (palette, dropdown, cheatsheet).
        case overlay

        var opacity: Float {
            switch self {
            case .none: return 0
            case .elevation1: return 0.10
            case .elevation2: return 0.18
            case .overlay: return 0.38
            }
        }

        var radius: CGFloat {
            switch self {
            case .none: return 0
            case .elevation1: return 4
            case .elevation2: return 9
            case .overlay: return 30
            }
        }

        var offsetY: CGFloat {
            switch self {
            case .none: return 0
            case .elevation1: return -1
            case .elevation2: return -3
            case .overlay: return -16
            }
        }
    }

    static func applyShadow(_ shadow: Shadow, to layer: CALayer?) {
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = shadow.opacity
        layer.shadowRadius = shadow.radius
        layer.shadowOffset = NSSize(width: 0, height: shadow.offsetY)
    }

    /// Resting/hover chrome for the circular icon buttons in the sidebar footer and
    /// the notification bell. The tab strip does not use this — those controls are
    /// plain glyphs (`applyGlyphButtonChrome`).
    /// Flat by design (no drop shadow): the whole window is one continuous surface, and
    /// hover is the only state that lifts. Both `SoftIconButton` and `NotificationBellButton`
    /// call this so they can never drift apart.
    static func applyIconButtonChrome(to layer: CALayer?, bounds: CGRect, isHovered: Bool) {
        guard let layer else { return }
        let c = chrome
        layer.cornerCurve = .continuous
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        layer.borderWidth = 1
        layer.borderColor = c.borderStrong.cgColor
        // Resting = the same elevated surface as the search field; hover lifts toward
        // the foreground so the affordance reads without a heavy fill or shadow.
        let resting = c.surfaceElevated
        let hover = c.textPrimary.withAlphaComponent(c.isDark ? 0.14 : 0.12)
        layer.backgroundColor = (isHovered ? hover : resting).cgColor
        applyShadow(.none, to: layer)
    }

    /// Tab-strip controls (sidebar toggle, new tab, overflow). No disc and no stroke.
    /// Hover is a rounded square, never a circle — a square hit target at half its
    /// height would read as the same ring the tab row just lost.
    static func applyGlyphButtonChrome(to layer: CALayer?, bounds: CGRect, isHovered: Bool) {
        guard let layer else { return }
        let c = chrome
        layer.cornerCurve = .continuous
        layer.cornerRadius = Radius.card
        layer.borderWidth = 0
        layer.borderColor = nil
        layer.backgroundColor = (isHovered ? c.iconHoverFill : NSColor.clear).cgColor
        applyShadow(.none, to: layer)
    }

    /// Label cell that draws chrome type in grayscale. LCD smoothing assumes an
    /// opaque system control; on light glass and a translucent window it fringes.
    static func prepareChromeLabel(_ field: NSTextField) {
        let cell = ChromeLabelCell(textCell: field.stringValue)
        cell.isEditable = false
        cell.isSelectable = false
        cell.isBordered = false
        cell.drawsBackground = false
        cell.backgroundStyle = .normal
        cell.font = field.font
        cell.alignment = field.alignment
        cell.lineBreakMode = field.lineBreakMode
        cell.usesSingleLineMode = true
        cell.truncatesLastVisibleLine = true
        field.cell = cell
        field.drawsBackground = false
        field.isBezeled = false
        field.isBordered = false
        field.isEditable = false
        field.isSelectable = false
        field.maximumNumberOfLines = 1
        field.backgroundColor = .clear
    }

    static func applyChromeLabelAppearance(_ fields: [NSTextField], isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        for field in fields {
            field.appearance = appearance
        }
    }

    /// Snap label frames onto the backing grid so stems don't bloom on Retina.
    static func alignChromeText(_ labels: [NSView], in host: NSView) {
        for label in labels {
            let aligned = host.backingAlignedRect(label.frame, options: [.alignAllEdgesNearest])
            let dx = abs(aligned.origin.x - label.frame.origin.x)
            let dy = abs(aligned.origin.y - label.frame.origin.y)
            if dx > 0.01 || dy > 0.01 {
                label.frame = aligned
            }
        }
    }

    enum ChromeRole {
        case sidebar
        case tabBar
    }

    /// Installs (or refreshes) a vibrancy + tint backdrop on `view`. Subsequent
    /// calls keep the same NSVisualEffectView and just update the tint, so chrome
    /// changes don't churn the view tree.
    @discardableResult
    static func installChromeBackground(_ role: ChromeRole, on view: NSView) -> ChromeBackdrop {
        let backdrop: ChromeBackdrop
        if let existing = view.subviews.first(where: { $0 is ChromeBackdrop }) as? ChromeBackdrop {
            backdrop = existing
        } else {
            backdrop = ChromeBackdrop(role: role)
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(backdrop, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                backdrop.topAnchor.constraint(equalTo: view.topAnchor),
                backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }
        backdrop.update(role: role)
        return backdrop
    }

    static func applySidebarChrome(to view: NSView) {
        // Same canvas color and the same paint opacity as the terminal.
        installChromeBackground(.sidebar, on: view)
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Shared glass tint for the active tab and the selected session card.
    static func activeGlassTint(isDark: Bool, textPrimary: NSColor) -> NSColor {
        isDark
            ? textPrimary.withAlphaComponent(0.14)
            : NSColor.white.withAlphaComponent(0.22)
    }

    static func activeGlassBorderAlpha(isDark: Bool) -> CGFloat {
        isDark ? 0.22 : 0.10
    }

    static func applyTabBarChrome(to view: NSView) {
        installChromeBackground(.tabBar, on: view)
    }

    static func makeClear(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// Hairline divider — quieter than 1px, only visible when needed.
    static func divider() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = chrome.border.cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    static func shortenPath(_ path: String) -> String {
        if path == "/" { return "/" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func pathDisplayName(_ path: String) -> String {
        let shortened = shortenPath(path)
        if shortened == "/" || shortened == "~" { return shortened }
        let last = (shortened as NSString).lastPathComponent
        return last.isEmpty ? shortened : last
    }

    /// Plain glyph button, same weight and hit target as the tab-strip icons.
    static func softIconButton(symbol: String, tooltip: String, size: CGFloat = chromeIconButtonSize) -> SoftIconButton {
        let button = SoftIconButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.style = .glyph
        button.setSymbol(symbol, accessibilityDescription: tooltip, pointSize: chromeIconPointSize, weight: .medium)
        button.toolTip = tooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: size),
            button.heightAnchor.constraint(equalToConstant: size),
        ])
        return button
    }

    /// Backwards-compatible alias used by older call sites.
    static func footerIconButton(symbol: String, tooltip: String) -> SoftIconButton {
        softIconButton(symbol: symbol, tooltip: tooltip)
    }
}

/// Centralized animation helpers so motion stays consistent and tasteful across
/// the app. Callers animate through the `animator()` proxy inside `animate`.
@MainActor
enum HarnessMotion {
    /// Run an animation group with one of the shared durations + easing curves.
    /// `completion` is `@MainActor`-isolated (hence `Sendable`) and bridged onto the
    /// main thread, where `runAnimationGroup` always invokes its handler.
    static func animate(
        _ duration: TimeInterval = HarnessDesign.Motion.fast,
        timing: CAMediaTimingFunction = HarnessDesign.Motion.standardEase,
        _ body: (NSAnimationContext) -> Void,
        completion: (@MainActor () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            body(ctx)
        }, completionHandler: completion.map { handler in
            { @Sendable in MainActor.assumeIsolated { handler() } }
        })
    }

    /// Cross-dissolve a layer whose contents are about to swap (theme change, pane
    /// remount). Soft transition instead of a hard cut; the swap itself is the
    /// caller's responsibility — this only schedules the fade.
    static func crossfade(_ layer: CALayer?, duration: TimeInterval = HarnessDesign.Motion.fast) {
        guard let layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = duration
        transition.timingFunction = HarnessDesign.Motion.standardEase
        layer.add(transition, forKey: "harnessCrossfade")
    }

    /// Gentle infinite halo pulse for "working" agent indicators. Adds/removes a
    /// `transform.scale` + `opacity` animation pair keyed on `"harnessPulse"`.
    static func startPulse(_ layer: CALayer?, minScale: CGFloat = 1.0, maxScale: CGFloat = 1.55, duration: TimeInterval = 1.4) {
        guard let layer else { return }
        if layer.animation(forKey: "harnessPulse") != nil { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = minScale
        scale.toValue = maxScale
        scale.duration = duration
        scale.autoreverses = true
        scale.repeatCount = .infinity
        scale.timingFunction = HarnessDesign.Motion.standardEase
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = 0.45
        opacity.duration = duration
        opacity.autoreverses = true
        opacity.repeatCount = .infinity
        opacity.timingFunction = HarnessDesign.Motion.standardEase
        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = duration * 2
        group.repeatCount = .infinity
        layer.add(group, forKey: "harnessPulse")
    }

    static func stopPulse(_ layer: CALayer?) {
        layer?.removeAnimation(forKey: "harnessPulse")
    }
}

/// Chrome label that antialiases in grayscale and on whole pixels. LCD subpixel
/// smoothing against a clear layer is what makes light-mode chrome type look soft.
final class ChromeLabelCell: NSTextFieldCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let context = NSGraphicsContext.current?.cgContext else {
            super.drawInterior(withFrame: cellFrame, in: controlView)
            return
        }
        let aligned = controlView.backingAlignedRect(cellFrame, options: [.alignAllEdgesNearest])
        context.saveGState()
        context.setShouldSmoothFonts(false)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        super.drawInterior(withFrame: aligned, in: controlView)
        context.restoreGState()
    }
}

/// Icon button. `.disc` is the footer / bell well. `.glyph` is a plain symbol —
/// the tab strip uses it so the sidebar toggle and new-tab control match the pills.
@MainActor
final class SoftIconButton: NSButton {
    enum Style { case disc, glyph }

    var style: Style = .disc { didSet { applyChrome() } }

    private let iconView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        wantsLayer = true
        layer?.cornerCurve = .continuous
        // NSButton defaults to a rounded bezel which conflicts with our
        // layer-driven chrome (the bezel intercepts hit-testing in some macOS
        // builds). Disable it so we own the look and clicks dispatch reliably.
        isBordered = false
        isTransparent = true
        bezelStyle = .regularSquare
        imagePosition = .noImage
        setButtonType(.momentaryChange)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        let iconWidth = iconView.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.58)
        let iconHeight = iconView.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.58)
        iconWidth.priority = .defaultHigh
        iconHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconHeight,
        ])

        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func layout() {
        super.layout()
        applyChrome()
    }

    func setSymbol(
        _ symbol: String,
        accessibilityDescription: String?,
        pointSize: CGFloat,
        weight: NSFont.Weight
    ) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(config)
        applyChrome()
    }

    func applyChrome() {
        switch style {
        case .disc:
            HarnessDesign.applyIconButtonChrome(to: layer, bounds: bounds, isHovered: isHovered)
            iconView.imageScaling = .scaleProportionallyUpOrDown
        case .glyph:
            HarnessDesign.applyGlyphButtonChrome(to: layer, bounds: bounds, isHovered: isHovered)
            // Never scale a symbol up into the hit target — that softens the stroke.
            iconView.imageScaling = .scaleProportionallyDown
        }
        let c = HarnessDesign.chrome
        iconView.contentTintColor = isHovered ? c.textPrimary : c.textSecondary
        iconView.appearance = NSAppearance(named: c.isDark ? .darkAqua : .aqua)
    }
}

/// Theme-aware pill button used for primary/secondary actions across onboarding and
/// settings. Monochrome on purpose: the chrome reads as one surface, and the only accent is
/// the theme's own (its cursor color), never the system accent. `.primary`
/// is a filled near-foreground pill with an on-canvas (background-colored) label;
/// `.secondary` is a quiet outlined pill. Manages its own tracking area + chrome,
/// mirroring `SoftIconButton`.
@MainActor
final class HarnessPillButton: NSButton {
    enum Kind { case primary, secondary }

    private let kind: Kind
    private let titleLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private var isPressed = false { didSet { applyChrome() } }

    init(title: String, kind: Kind = .primary) {
        self.kind = kind
        super.init(frame: .zero)
        self.title = ""
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(titleLabel)
        // Pin the label leading+trailing (not just centerX) so the button's intrinsic width
        // is driven by the label + 16pt of padding each side. Without this the button
        // collapses to a tiny square and clips its title (the old empty-pill bug).
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setTitleText(_ text: String) {
        titleLabel.stringValue = text
        applyChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) {
        isPressed = true
        super.mouseDown(with: event)
        isPressed = false
    }

    private func applyChrome() {
        let c = HarnessDesign.chrome
        switch kind {
        case .primary:
            // Filled near-foreground; label paints in the canvas color so it reads on
            // the bright fill regardless of theme (dark label on light themes too).
            let base = c.textPrimary
            let fill = isPressed
                ? base.withAlphaComponent(0.82)
                : (isHovered ? base.withAlphaComponent(0.92) : base)
            layer?.backgroundColor = fill.cgColor
            layer?.borderWidth = 0
            titleLabel.textColor = c.terminalBackground
        case .secondary:
            let resting = c.surfaceElevated
            let hover = c.textPrimary.withAlphaComponent(c.isDark ? 0.12 : 0.10)
            layer?.backgroundColor = (isPressed || isHovered ? hover : resting).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = (isHovered ? c.borderStrong : c.border).cgColor
            titleLabel.textColor = isHovered ? c.textPrimary : c.textSecondary
        }
    }
}

extension HarnessDesign {
    /// macOS 26 liquid glass. Nil on earlier systems, where the caller keeps a solid pill.
    static func makeLiquidGlass(cornerRadius: CGFloat) -> NSView? {
        RuntimeGlassEffectView.make(cornerRadius: cornerRadius)
    }

    static func setLiquidGlassTint(_ color: NSColor, on view: NSView) {
        RuntimeGlassEffectView.setTintColor(color, on: view)
    }

    static func setLiquidGlassCornerRadius(_ radius: CGFloat, on view: NSView) {
        view.setValue(NSNumber(value: Double(radius)), forKey: "cornerRadius")
    }
}

@MainActor
private enum RuntimeGlassEffectView {
    static func make(cornerRadius: CGFloat) -> NSView? {
        guard #available(macOS 26.0, *),
              let glassType = NSClassFromString("NSGlassEffectView") as? NSObject.Type,
              let glass = glassType.init() as? NSView else {
            return nil
        }
        glass.setValue(NSNumber(value: Double(cornerRadius)), forKey: "cornerRadius")
        return glass
    }

    static func isGlass(_ view: NSView) -> Bool {
        NSStringFromClass(type(of: view)).hasSuffix("NSGlassEffectView")
    }

    static func setTintColor(_ color: NSColor, on view: NSView) {
        view.setValue(color, forKey: "tintColor")
    }
}

/// Backdrop that blends an NSVisualEffectView with a thin tint overlay so the
/// chrome feels native (Terminal-style blur) while still respecting the
/// active theme color. When window opacity is fully opaque, the vibrancy view
/// stays in the tree but is hidden so we get a clean solid look.
@MainActor
final class ChromeBackdrop: NSView {
    private var role: HarnessDesign.ChromeRole
    /// Liquid Glass on macOS 26+, vibrancy fallback on earlier OS releases.
    private let backdrop: NSView
    private let tint = NSView()
    /// Hairline separator drawn at the bottom edge for the tab-bar role only, so the
    /// tab strip reads as distinct from the terminal without a hard divider.
    private let hairline = CALayer()

    /// When true, the next `update(role:)` cross-dissolves its color change instead of
    /// cutting. The chrome-change cascade (theme switch) sets this around its pass so a
    /// theme switch fades rather than pops. Scoped to backdrops (behind the terminal),
    /// so the Metal pane is never captured in the transition.
    static var crossfadeNextUpdate = false

    init(role: HarnessDesign.ChromeRole) {
        self.role = role
        self.backdrop = ChromeBackdrop.makeBackdrop()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false

        tint.translatesAutoresizingMaskIntoConstraints = false
        tint.wantsLayer = true

        addSubview(backdrop)
        addSubview(tint)
        layer?.addSublayer(hairline)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            tint.topAnchor.constraint(equalTo: topAnchor),
            tint.leadingAnchor.constraint(equalTo: leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: trailingAnchor),
            tint.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        update(role: role)
    }

    override func layout() {
        super.layout()
        // Manual frame (CALayer, not Auto Layout); AppKit suppresses implicit
        // animations during the layout pass so this doesn't slide on resize.
        hairline.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    /// Picks the best available backdrop layer:
    /// - macOS 26+ → `NSGlassEffectView` (real Liquid Glass)
    /// - earlier   → `NSVisualEffectView` with `.underWindowBackground`
    private static func makeBackdrop() -> NSView {
        if let glass = RuntimeGlassEffectView.make(cornerRadius: 0) {
            return glass
        }
        let vibrancy = NSVisualEffectView()
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .followsWindowActiveState
        return vibrancy
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Allow clicks to pass through the backdrop to the chrome's interactive
    /// children (workspace pill, session cards, tabs). Without this the vibrancy
    /// view eats hit-tests.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(role: HarnessDesign.ChromeRole) {
        self.role = role
        let chrome = HarnessDesign.chrome
        let opacity = HarnessChrome.paintOpacity

        if Self.crossfadeNextUpdate {
            HarnessMotion.crossfade(layer, duration: HarnessDesign.Motion.fast)
        }

        let baseColor: NSColor
        switch role {
        case .sidebar: baseColor = chrome.sidebarBackground
        case .tabBar: baseColor = chrome.sidebarBackground
        }

        // One tint over the window blur. Glass stays hidden while the window is
        // translucent so the sidebar and the terminal share one opacity.
        let translucent = opacity < 0.999
        if RuntimeGlassEffectView.isGlass(backdrop) {
            backdrop.isHidden = translucent
        } else if let vibrancy = backdrop as? NSVisualEffectView {
            vibrancy.material = material(for: role)
            vibrancy.isHidden = translucent
        }
        tint.layer?.backgroundColor = baseColor.withAlphaComponent(opacity).cgColor

        // No drawn hairline anywhere: the tab strip / sidebar / status line now read
        // as distinct from the terminal purely by their elevated chrome background
        // (see HarnessChromePalette.build), so a hard divider line is redundant noise.
        hairline.isHidden = true
        hairline.backgroundColor = chrome.border.withAlphaComponent(chrome.isDark ? 0.55 : 0.75).cgColor
        needsLayout = true
    }

    private func material(for role: HarnessDesign.ChromeRole) -> NSVisualEffectView.Material {
        // Not `.sidebar`/`.titlebar`: those add the system's own tint, which would fight
        // the theme. `.underWindowBackground` is a plain desktop blur under our theme tint.
        switch role {
        case .sidebar, .tabBar:
            return .underWindowBackground
        }
    }
}

/// Rounded, theme-tinted Liquid-Glass surface for floating overlays (command
/// palette, prefix cheatsheet/indicator). Add content to `contentView`; on macOS 26
/// it sits over real glass, otherwise over a vibrancy + tint fallback. Pair with a
/// borderless panel (`backgroundColor = .clear`, `hasShadow = true`).
///
/// Layered (back→front): backdrop → theme tint → top-edge highlight → contentView.
/// The 1px inner highlight gives a real "elevated surface" feel without resorting
/// to a heavier border.
@MainActor
final class HarnessOverlayBackground: NSView {
    let contentView = NSView()
    private let backdrop: NSView
    private let tint = NSView()
    /// Top-edge inner highlight — emulates the "rim light" on macOS popovers/menus.
    private let topHighlight = CALayer()

    init() {
        self.backdrop = HarnessOverlayBackground.makeBackdrop()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.overlay
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1

        tint.wantsLayer = true
        contentView.wantsLayer = true
        for sub in [backdrop, tint, contentView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            addSubview(sub)
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: topAnchor),
                sub.leadingAnchor.constraint(equalTo: leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: trailingAnchor),
                sub.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        // Highlight goes after tint but under contentView so children float above it.
        tint.layer?.addSublayer(topHighlight)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Manual frame (CALayer); implicit anim suppressed during layout.
        topHighlight.frame = CGRect(x: 1, y: bounds.height - 1, width: bounds.width - 2, height: 1)
    }

    private static func makeBackdrop() -> NSView {
        if let glass = RuntimeGlassEffectView.make(cornerRadius: HarnessDesign.Radius.overlay) {
            return glass
        }
        let vibrancy = NSVisualEffectView()
        vibrancy.material = .underWindowBackground
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        return vibrancy
    }

    func applyTheme() {
        let c = HarnessDesign.chrome
        layer?.borderColor = c.border.cgColor
        if RuntimeGlassEffectView.isGlass(backdrop) {
            // Tint the glass so it reads as an elevated dark surface while keeping blur.
            RuntimeGlassEffectView.setTintColor(c.sidebarBackground, on: backdrop)
            tint.layer?.backgroundColor = NSColor.clear.cgColor
        } else {
            tint.layer?.backgroundColor = c.sidebarBackground.withAlphaComponent(0.95).cgColor
        }
        // Soft inner highlight — brighter on dark themes, near-invisible on light.
        topHighlight.backgroundColor = c.textPrimary.withAlphaComponent(c.isDark ? 0.10 : 0.04).cgColor
    }
}

/// 8 px status indicator dot. Tints itself based on `TabStatus`.
@MainActor
final class StatusDotView: NSView {
    enum Style: Equatable {
        case idle
        case waiting
        case error
        case accent
        /// Tinted by the running agent (present/idle), with optional user overrides in settings.
        case agent(hex: String)
        /// Agent actively working — a gently breathing brand-tinted halo.
        case agentWorking(hex: String)
    }

    private let dot = CALayer()
    private let halo = CALayer()
    private let diameter: CGFloat

    var style: Style = .idle {
        didSet { if style != oldValue { applyStyle() } }
    }

    init(diameter: CGFloat = 14) {
        self.diameter = diameter
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: diameter)
        let height = heightAnchor.constraint(equalToConstant: diameter)
        width.priority = .defaultHigh
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([width, height])
        applyStyle()
        // Re-evaluate the breathing pulse when the user toggles Reduce Motion mid-session, so the
        // dot matches the live setting even while an agent keeps working (the style — and thus
        // applyStyle — would otherwise not change). Mirrors the notch's environment reactivity.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(reduceMotionDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func reduceMotionDidChange() {
        applyStyle()
    }

    override func layout() {
        super.layout()
        let dotSize: CGFloat = diameter * 0.5
        let haloSize: CGFloat = diameter
        dot.frame = CGRect(
            x: (bounds.width - dotSize) / 2,
            y: (bounds.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        dot.cornerRadius = dotSize / 2
        halo.frame = CGRect(
            x: (bounds.width - haloSize) / 2,
            y: (bounds.height - haloSize) / 2,
            width: haloSize,
            height: haloSize
        )
        halo.cornerRadius = haloSize / 2
    }

    func applyStyle() {
        let c = HarnessDesign.chrome
        dot.isHidden = false

        let color: NSColor
        var working = false
        switch style {
        case .idle: color = c.idleStatus
        case .waiting: color = c.waiting
        case .error: color = c.danger
        case .accent: color = c.accent
        case let .agent(hex): color = NSColor.fromHex(hex) ?? c.accent
        case let .agentWorking(hex): color = NSColor.fromHex(hex) ?? c.accent; working = true
        }
        dot.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(working ? 0.30 : 0.20).cgColor
        halo.isHidden = (style == .idle)
        // Only a working agent breathes — a calm, low-amplitude pulse (the earlier 1.55×/0.45
        // version read as busy). Everything else is a static ring. Honor Reduce Motion.
        if working, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            HarnessMotion.startPulse(halo, minScale: 1.0, maxScale: 1.32, duration: 1.6)
        } else {
            HarnessMotion.stopPulse(halo)
        }
    }
}

@MainActor
final class AgentChipView: NSView {
    private let iconView = NSImageView()
    private let iconSize: CGFloat = 16

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: iconSize, height: iconSize)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 0
    }

    func configure(kind: AgentKind, hex: String) {
        let tint = NSColor.fromHex(hex) ?? HarnessDesign.chrome.accent
        iconView.image = AgentIconRenderer.templateOrMonogramImage(for: kind, size: iconSize)
        iconView.contentTintColor = tint
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        toolTip = kind.displayName
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

extension NSColor {
    static func fromHex(_ raw: String) -> NSColor? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xff) / 255
        let g = CGFloat((value >> 8) & 0xff) / 255
        let b = CGFloat(value & 0xff) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
