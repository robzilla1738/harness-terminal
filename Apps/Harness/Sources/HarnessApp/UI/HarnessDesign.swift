import AppKit

/// Layout metrics and chrome helpers; colors come from `HarnessChrome.current`.
@MainActor
enum HarnessDesign {
    static let sidebarWidth: CGFloat = 264
    static let titlebarChromeHeight: CGFloat = 44
    static let tabBarHeight: CGFloat = 32
    static let workspaceBarHeight: CGFloat = 42
    static let sessionRowHeight: CGFloat = 54
    static let footerHeight: CGFloat = 40
    static let tabPillHeight: CGFloat = 24

    static let horizontalInset: CGFloat = 12
    static let rowSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 7
    static let pillCornerRadius: CGFloat = 5

    static var chrome: HarnessChromePalette { HarnessChrome.current }

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

        if let vibrancy = backdrop as? NSVisualEffectView {
            vibrancy.material = material(for: role)
            vibrancy.isHidden = !isTransparent
        } else {
            // Liquid Glass: just hide the layer when fully opaque so we get a
            // crisp solid color without any blur.
            backdrop.isHidden = !isTransparent
        }

        let baseColor: NSColor
        switch role {
        case .sidebar: baseColor = chrome.sidebarBackground
        case .terminal: baseColor = chrome.terminalBackground
        case .tabBar: baseColor = chrome.sidebarBackground
        }

        if isTransparent {
            // Tint sits ON TOP of vibrancy, providing the Ghostty background
            // color × opacity (e.g. pure-black @ 0.85) across every region.
            tint.layer?.backgroundColor = baseColor.withAlphaComponent(opacity).cgColor
        } else {
            tint.layer?.backgroundColor = baseColor.cgColor
        }
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

/// 8 px status indicator dot. Tints itself based on `TabStatus`.
@MainActor
final class StatusDotView: NSView {
    enum Style: Equatable {
        case idle
        case waiting
        case error
        case accent
        /// Tinted by the running agent (see `AgentKind.dotHex`).
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
        halo.backgroundColor = color.withAlphaComponent(0.18).cgColor
        halo.isHidden = style == .idle
    }
}

/// Two-letter pill that identifies the agent (e.g. "CC" for Claude Code) on
/// each session card.
@MainActor
final class AgentChipView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous

        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, hex: String) {
        label.stringValue = text
        let tint = NSColor.fromHex(hex) ?? HarnessDesign.chrome.accent
        layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor
        label.textColor = tint
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
