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
    static let titlebarChromeHeight: CGFloat = 44
    static let tabBarHeight: CGFloat = 34
    static let workspaceBarHeight: CGFloat = 42
    static let sessionRowHeight: CGFloat = 54
    static let footerHeight: CGFloat = 40
    static let tabPillHeight: CGFloat = 26

    static let horizontalInset: CGFloat = Spacing.lg
    static let rowSpacing: CGFloat = Spacing.xxs
    static let cornerRadius: CGFloat = Radius.card
    static let pillCornerRadius: CGFloat = Radius.pill

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

    /// Corner-radius vocabulary. Pair every use with `.cornerCurve = .continuous`.
    enum Radius {
        static let card: CGFloat = 7
        static let pill: CGFloat = 5
        static let badge: CGFloat = 4
        static let control: CGFloat = 6
        static let overlay: CGFloat = 10
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

    /// Resting/hover chrome for the small circular icon buttons that live in the chrome
    /// (notification bell, sidebar toggle, footer gear/＋/palette, tab strip ＋/overflow).
    /// One source of truth so every icon button reads as the *same* themed disc — the
    /// same `surfaceElevated` fill + `borderStrong` rim the search field beside them
    /// uses — instead of an opaque near-black circle that floats above the chrome.
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
        installChromeBackground(.sidebar, on: view)
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

    /// Soft icon button with circular hover fill — used in footer / workspace bar.
    static func softIconButton(symbol: String, tooltip: String, size: CGFloat = 26) -> SoftIconButton {
        let button = SoftIconButton(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.setSymbol(symbol, accessibilityDescription: tooltip, pointSize: 12, weight: .medium)
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

/// Round, hover-tinted icon button. Manages its own tracking area + chrome.
@MainActor
final class SoftIconButton: NSButton {
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
        HarnessDesign.applyIconButtonChrome(to: layer, bounds: bounds, isHovered: isHovered)
        let c = HarnessDesign.chrome
        iconView.contentTintColor = isHovered ? c.textPrimary : c.textSecondary
    }
}

/// Theme-aware pill button used for primary/secondary actions across onboarding and
/// settings. Deliberately monochrome — the app's deep-black chrome reads as one
/// surface, so we never tint these with the system accent (no macOS blue). `.primary`
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
        let opacity = HarnessChrome.backgroundOpacity

        if Self.crossfadeNextUpdate {
            HarnessMotion.crossfade(layer, duration: HarnessDesign.Motion.fast)
        }

        let baseColor: NSColor
        switch role {
        case .sidebar: baseColor = chrome.sidebarBackground
        case .tabBar: baseColor = chrome.sidebarBackground
        }

        // Unified canvas: when the window is translucent, ONE window-wide CGS blur
        // (MainWindowController) is the single blur source, so the chrome's own
        // vibrancy/glass material is hidden — the tint alone (bg × opacity) lets the
        // shared blurred backdrop show through, matching the terminal exactly. When
        // opaque, the solid tint covers everything, so the material is moot.
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
        // We deliberately avoid `.sidebar`/`.titlebar` here — those materials
        // add a noticeable blue tint that breaks the deep-black look.
        // `.underWindowBackground` gives an honest desktop blur that we then
        // dim with our own theme tint on top.
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
        layer?.borderColor = c.borderStrong.cgColor
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
        /// Agent finished and is waiting on you — amber "needs you".
        case attention
        /// Agent just finished cleanly — a brief green check before settling to idle.
        case done
    }

    private let dot = CALayer()
    private let halo = CALayer()
    private let checkView = NSImageView()
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
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.imageScaling = .scaleProportionallyUpOrDown
        checkView.isHidden = true
        checkView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Agent finished")
        checkView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: max(7, diameter * 0.64), weight: .bold)
        addSubview(checkView)
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: diameter)
        let height = heightAnchor.constraint(equalToConstant: diameter)
        width.priority = .defaultHigh
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width, height,
            checkView.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkView.trailingAnchor.constraint(equalTo: trailingAnchor),
            checkView.topAnchor.constraint(equalTo: topAnchor),
            checkView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
        // The "done" check is its own affordance — swap the dot/halo out for a green checkmark.
        if case .done = style {
            HarnessMotion.stopPulse(halo)
            dot.isHidden = true
            halo.isHidden = true
            checkView.isHidden = false
            checkView.contentTintColor = c.success
            return
        }
        checkView.isHidden = true
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
        case .attention: color = c.attention
        case .done: color = c.success // unreachable (handled above); keeps the switch exhaustive
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

/// Clean capsule that names the running agent (e.g. "Codex", "Claude Code") on
/// each session card: a small brand-colored dot followed by the tool's name on a
/// faint brand-tinted fill.
@MainActor
final class AgentChipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    /// Icon edge length when a brand mark is shown.
    private let iconSize: CGFloat = 16
    private var showingIcon = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous

        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.isHidden = true
        addSubview(iconView)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: iconSize),
            iconView.heightAnchor.constraint(equalToConstant: iconSize),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        showingIcon
            ? NSSize(width: iconSize, height: iconSize)
            : NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = showingIcon ? 0 : bounds.height / 2
    }

    /// Brand identity for an agent: the tinted vector icon when one exists, else a
    /// hairline-outlined name pill. The dot was removed; the icon carries the brand.
    func configure(kind: AgentKind, hex: String) {
        let tint = NSColor.fromHex(hex) ?? HarnessDesign.chrome.accent
        if let icon = AgentIconRenderer.templateImage(for: kind, size: iconSize) {
            showingIcon = true
            iconView.image = icon
            iconView.contentTintColor = tint
            iconView.isHidden = false
            label.isHidden = true
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            toolTip = kind.displayName
        } else {
            configure(text: kind.displayName, hex: hex)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Outline-only name pill (no washed fill) — used for agents without a brand mark.
    func configure(text: String, hex: String) {
        showingIcon = false
        iconView.isHidden = true
        label.isHidden = false
        label.stringValue = text
        toolTip = text
        let tint = NSColor.fromHex(hex) ?? HarnessDesign.chrome.accent
        let c = HarnessDesign.chrome
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(c.isDark ? 0.55 : 0.45).cgColor
        label.textColor = c.textPrimary.withAlphaComponent(0.94)
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
