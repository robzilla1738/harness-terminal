import AppKit
import QuartzCore

/// Layout metrics and chrome helpers; colors come from `HarnessChrome.current`.
@MainActor
enum HarnessDesign {
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
        static var rowTitle: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
        static var rowMeta: NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }
        static var tabTitle: NSFont { .systemFont(ofSize: 12, weight: .medium) }
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

    enum ChromeRole {
        case sidebar
        case terminal
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

    static func applyTerminalChrome(to view: NSView) {
        installChromeBackground(.terminal, on: view)
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
        layer?.cornerRadius = min(bounds.width, bounds.height) / 2
        let c = HarnessDesign.chrome
        layer?.borderWidth = 1
        layer?.borderColor = (isHovered ? c.textPrimary.withAlphaComponent(0.20) : c.textPrimary.withAlphaComponent(0.12)).cgColor
        let base = c.terminalBackground.blended(withFraction: c.isDark ? 0.045 : 0.035, of: c.textPrimary) ?? c.terminalBackground
        let hover = c.terminalBackground.blended(withFraction: c.isDark ? 0.085 : 0.07, of: c.textPrimary) ?? c.iconHoverFill
        layer?.backgroundColor = (isHovered ? hover : base).withAlphaComponent(c.isDark ? 0.96 : 0.86).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = isHovered ? 0.20 : 0.08
        layer?.shadowRadius = isHovered ? 6 : 3
        layer?.shadowOffset = NSSize(width: 0, height: -1)
        iconView.contentTintColor = isHovered ? c.textPrimary : c.textSecondary
    }
}

/// Backdrop that blends an NSVisualEffectView with a thin tint overlay so the
/// chrome feels native (Ghostty/Terminal-style blur) while still respecting the
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
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 0
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
        let isTransparent = opacity < 0.999

        if Self.crossfadeNextUpdate {
            HarnessMotion.crossfade(layer, duration: HarnessDesign.Motion.fast)
        }

        let baseColor: NSColor
        switch role {
        case .sidebar: baseColor = chrome.sidebarBackground
        case .terminal: baseColor = chrome.terminalBackground
        case .tabBar: baseColor = chrome.sidebarBackground
        }

        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            if isTransparent {
                // Tint the Liquid Glass material itself so its blur/refraction shows
                // through. (A flat opaque overlay on top would defeat the glass.) The
                // glass owns its translucency, so on macOS 26 the opacity slider acts
                // as a translucent↔solid switch rather than a precise alpha.
                glass.isHidden = false
                glass.tintColor = baseColor
                tint.layer?.backgroundColor = NSColor.clear.cgColor
            } else {
                // Fully opaque → drop the glass for a crisp solid color (true black).
                glass.isHidden = true
                tint.layer?.backgroundColor = baseColor.cgColor
            }
        } else if let vibrancy = backdrop as? NSVisualEffectView {
            vibrancy.material = material(for: role)
            vibrancy.isHidden = !isTransparent
            // Tint sits ON TOP of vibrancy, providing the Ghostty background
            // color × opacity (e.g. pure-black @ 0.85) across every region.
            tint.layer?.backgroundColor = baseColor.cgColor
        }

        // Tab strip gets a quiet hairline at its bottom edge to anchor the active
        // pill against the terminal area below. Sidebar/terminal stay clean.
        hairline.isHidden = role != .tabBar
        hairline.backgroundColor = chrome.border.withAlphaComponent(chrome.isDark ? 0.55 : 0.75).cgColor
        needsLayout = true
    }

    private func material(for role: HarnessDesign.ChromeRole) -> NSVisualEffectView.Material {
        // We deliberately avoid `.sidebar`/`.titlebar` here — those materials
        // add a noticeable blue tint that breaks the deep-black Ghostty look.
        // `.underWindowBackground` gives an honest desktop blur that we then
        // dim with our own theme tint on top.
        switch role {
        case .sidebar, .terminal, .tabBar:
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
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = HarnessDesign.Radius.overlay
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
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            // Tint the glass so it reads as an elevated dark surface while keeping blur.
            glass.tintColor = c.sidebarBackground
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
        /// Tinted by the running agent, with optional user overrides in settings.
        case agent(hex: String)
    }

    private let dot = CALayer()
    private let halo = CALayer()

    var style: Style = .idle {
        didSet { applyStyle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(halo)
        layer?.addSublayer(dot)
        translatesAutoresizingMaskIntoConstraints = false
        let width = widthAnchor.constraint(equalToConstant: 14)
        let height = heightAnchor.constraint(equalToConstant: 14)
        width.priority = .defaultHigh
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([width, height])
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let dotSize: CGFloat = 7
        let haloSize: CGFloat = 14
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
        let color: NSColor
        switch style {
        case .idle: color = c.idleStatus
        case .waiting: color = c.waiting
        case .error: color = c.danger
        case .accent: color = c.accent
        case let .agent(hex): color = NSColor.fromHex(hex) ?? c.accent
        }
        dot.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(0.20).cgColor
        halo.isHidden = style == .idle
        // The halo gently pulses when the dot signals live activity (agent working
        // or a waiting notification). Idle/error/accent are static so the strip
        // doesn't feel busy.
        switch style {
        case .agent, .waiting:
            HarnessMotion.startPulse(halo, minScale: 0.92, maxScale: 1.45, duration: 1.25)
        case .idle, .error, .accent:
            HarnessMotion.stopPulse(halo)
        }
    }
}

/// Clean capsule that names the running agent (e.g. "Codex", "Claude Code") on
/// each session card: a small brand-colored dot followed by the tool's name on a
/// faint brand-tinted fill.
@MainActor
final class AgentChipView: NSView {
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.addSublayer(dot)

        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            // Leading room reserves space for the dot drawn in layout().
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 17),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Capsule, with a 5px dot vertically centered against the leading inset.
        layer?.cornerRadius = bounds.height / 2
        let size: CGFloat = 5
        dot.frame = CGRect(x: 8, y: (bounds.height - size) / 2, width: size, height: size)
        dot.cornerRadius = size / 2
    }

    func configure(text: String, hex: String) {
        label.stringValue = text
        let tint = NSColor.fromHex(hex) ?? HarnessDesign.chrome.accent
        let c = HarnessDesign.chrome
        layer?.backgroundColor = tint.withAlphaComponent(c.isDark ? 0.16 : 0.13).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = tint.withAlphaComponent(c.isDark ? 0.22 : 0.20).cgColor
        dot.backgroundColor = tint.cgColor
        // Brand color reads poorly as text on dark fills for some agents, so lean on
        // a bright, legible label and let the dot carry the brand hue.
        label.textColor = c.textPrimary.withAlphaComponent(0.94)
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
