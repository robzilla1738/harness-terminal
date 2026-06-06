import AppKit

// Lightweight form controls for Settings. They mirror the value/`target`-`action`
// surface of the stock AppKit controls they replace, while drawing with the app's
// themed `HarnessChrome.current` palette so the Settings window reads as one surface
// with the rest of Harness (deep, monochrome — never the macOS accent blue).
//
// Construction idiom matches `SoftIconButton` / `SettingsSidebarButton`: own tracking area,
// `applyChrome()` re-derives colors on hover/state/theme changes, `.cornerCurve = .continuous`.
// `applyChrome()` is intentionally non-private so the host (`SettingsViewController`) can
// re-skin every control live when the theme changes while the window is open.

// MARK: - Themed text field

/// Inset cell so themed fields get horizontal padding + vertical centering (the rounded
/// background is drawn by `HarnessTextField`'s layer, not a system bezel).
final class HarnessTextFieldCell: NSTextFieldCell {
    var horizontalInset: CGFloat = 8

    private func inset(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize(forBounds: rect).height
        let y = rect.minY + (rect.height - textHeight) / 2
        return NSRect(x: rect.minX + horizontalInset, y: y,
                      width: max(0, rect.width - horizontalInset * 2), height: textHeight)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: inset(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: controlView, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: inset(rect), in: controlView, editor: editor, delegate: delegate, start: selStart, length: selLength)
    }
}

/// Single-line editable field with a themed rounded background, no system bezel, and no
/// blue focus ring (the border takes the theme accent via `focusRing` on focus instead).
@MainActor
final class HarnessTextField: NSTextField {
    private var focused = false

    override class var cellClass: AnyClass? {
        get { HarnessTextFieldCell.self }
        set {}
    }

    init() {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        // Commit on focus-loss too (not only Enter), so editing a value and clicking
        // away still fires the control's action.
        (cell as? NSTextFieldCell)?.sendsActionOnEndEditing = true
        font = .systemFont(ofSize: 12)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        applyChrome()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { focused = true; applyChrome() }
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focused = false
        applyChrome()
    }

    func applyChrome() {
        let c = HarnessChrome.current
        layer?.backgroundColor = c.surfaceElevated.cgColor
        layer?.borderColor = (focused ? c.focusRing : c.border).cgColor
        textColor = c.textPrimary
    }
}

// MARK: - Themed search field (plain field + static magnifier, no blue ring)

/// Reusable search field copied from the sidebar pattern: a `surfaceElevated` rounded
/// container with a static magnifier and a plain `NSTextField` (no `NSSearchField`
/// search-button cell, so focus never collapses the field or paints a blue ring).
@MainActor
final class HarnessSearchField: NSView, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    private let field = NSTextField()
    private let magnifier = NSImageView()

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var placeholderString: String? {
        get { field.placeholderString }
        set { field.placeholderString = newValue }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(glyph)
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        magnifier.imageScaling = .scaleProportionallyDown

        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        addSubview(magnifier)
        addSubview(field)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            magnifier.centerYAnchor.constraint(equalTo: centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 13),
            magnifier.heightAnchor.constraint(equalToConstant: 13),
            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 7),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        applyChrome()
    }

    // Forward focus to the inner field so clicking/`makeFirstResponder` lands in the
    // editable text (the container itself is non-editable).
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(field) ?? false
    }

    func applyChrome() {
        let c = HarnessChrome.current
        layer?.backgroundColor = c.surfaceElevated.cgColor
        layer?.borderColor = c.border.cgColor
        magnifier.contentTintColor = c.textTertiary
        field.textColor = c.textPrimary
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }
}

// MARK: - Toggle (switch)

/// Monochrome switch replacing `NSButton(checkboxWithTitle:)` / `setButtonType(.switch)`.
/// ON fills the track with `textPrimary`; OFF is a quiet `surfaceElevated` capsule.
@MainActor
final class HarnessToggle: NSControl {
    private let track = CALayer()
    private let knob = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }

    private static let trackWidth: CGFloat = 38
    private static let trackHeight: CGFloat = 22
    private static let knobSize: CGFloat = 18

    var state: NSControl.StateValue = .off {
        didSet {
            guard state != oldValue else { return }
            animateKnob(); applyChrome()
            setAccessibilityValue(state == .on)
        }
    }

    var title: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.isHidden = newValue.isEmpty
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        track.cornerCurve = .continuous
        knob.cornerCurve = .continuous
        layer?.addSublayer(track)
        layer?.addSublayer(knob)

        label.font = .systemFont(ofSize: 12)
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.trackWidth + 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(false)
        applyChrome()
    }

    convenience init(title: String) {
        self.init(frame: .zero)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let labelWidth = label.isHidden ? 0 : (8 + label.intrinsicContentSize.width)
        return NSSize(width: Self.trackWidth + labelWidth, height: Self.trackHeight)
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Self.trackHeight) / 2
        track.frame = NSRect(x: 0, y: y, width: Self.trackWidth, height: Self.trackHeight)
        track.cornerRadius = Self.trackHeight / 2
        knob.cornerRadius = Self.knobSize / 2
        positionKnob(animated: false)
        applyChrome()
    }

    private func positionKnob(animated: Bool) {
        let y = (bounds.height - Self.knobSize) / 2
        let onX = Self.trackWidth - Self.knobSize - 2
        let x = state == .on ? onX : 2
        let frame = NSRect(x: x, y: y, width: Self.knobSize, height: Self.knobSize)
        if animated {
            HarnessMotion.animate(HarnessDesign.Motion.fast) { _ in knob.frame = frame }
        } else {
            // Suppress implicit animation during layout.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            knob.frame = frame
            CATransaction.commit()
        }
    }

    private func animateKnob() { positionKnob(animated: true) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        state = state == .on ? .off : .on
        if let action { _ = NSApp.sendAction(action, to: target, from: self) }
    }

    func applyChrome() {
        let c = HarnessChrome.current
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if state == .on {
            // Monochrome ON: a near-foreground filled track with an on-canvas knob,
            // matching `HarnessPillButton.primary`. The app never uses the macOS accent.
            track.backgroundColor = c.textPrimary.cgColor
            track.borderWidth = 0
            knob.backgroundColor = c.terminalBackground.cgColor
        } else {
            track.backgroundColor = c.surfaceElevated.cgColor
            track.borderWidth = 1
            track.borderColor = (isHovered ? c.borderStrong : c.border).cgColor
            knob.backgroundColor = c.textSecondary.cgColor
        }
        CATransaction.commit()
        label.textColor = c.textPrimary
    }
}

// MARK: - Slider

/// Monochrome continuous slider replacing `NSSlider`. Filled portion `textPrimary`,
/// remainder `surfaceElevated`, knob a `textPrimary` disc. Built from scratch so no
/// system cell draws an opaque bezel.
@MainActor
final class HarnessSlider: NSControl {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let knob = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isActive = false { didSet { applyChrome() } }

    var minValue: Double = 0
    var maxValue: Double = 1
    private var value: Double = 0

    /// Fired once when an interactive drag finishes (mouse-up), distinct from the per-tick `action`
    /// that fires continuously while dragging. Lets a continuous slider apply live on every tick but
    /// persist (a full JSON encode + atomic write) only once at the end of the gesture.
    var onCommit: (() -> Void)?

    private static let knobSize: CGFloat = 14
    private static let trackHeight: CGFloat = 4

    override var doubleValue: Double {
        get { value }
        set { value = min(maxValue, max(minValue, newValue)); needsLayout = true; setAccessibilityValue(value) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isContinuous = true
        for l in [trackLayer, fillLayer, knob] { l.cornerCurve = .continuous; layer?.addSublayer(l) }
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        setAccessibilityRole(.slider)
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var fraction: CGFloat {
        let span = maxValue - minValue
        return span <= 0 ? 0 : CGFloat((value - minValue) / span)
    }

    override func layout() {
        super.layout()
        let midY = bounds.midY
        let usable = bounds.width - Self.knobSize
        let knobX = Self.knobSize / 2 + usable * fraction
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trackLayer.frame = NSRect(x: Self.knobSize / 2, y: midY - Self.trackHeight / 2,
                                  width: max(0, bounds.width - Self.knobSize), height: Self.trackHeight)
        trackLayer.cornerRadius = Self.trackHeight / 2
        fillLayer.frame = NSRect(x: Self.knobSize / 2, y: midY - Self.trackHeight / 2,
                                 width: max(0, usable * fraction), height: Self.trackHeight)
        fillLayer.cornerRadius = Self.trackHeight / 2
        knob.frame = NSRect(x: knobX - Self.knobSize / 2, y: midY - Self.knobSize / 2,
                            width: Self.knobSize, height: Self.knobSize)
        knob.cornerRadius = Self.knobSize / 2
        CATransaction.commit()
        applyChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isActive = true }
    override func mouseExited(with event: NSEvent) { if currentDrag == false { isActive = false } }

    private var currentDrag = false
    override func mouseDown(with event: NSEvent) {
        currentDrag = true
        isActive = true
        updateFromEvent(event, commit: isContinuous)
    }
    override func mouseDragged(with event: NSEvent) {
        updateFromEvent(event, commit: isContinuous)
    }
    override func mouseUp(with event: NSEvent) {
        updateFromEvent(event, commit: true)
        // The gesture is over: let an observer persist once (the per-tick `action` only applied live).
        onCommit?()
        currentDrag = false
        let point = convert(event.locationInWindow, from: nil)
        if !bounds.contains(point) { isActive = false }
    }

    private func updateFromEvent(_ event: NSEvent, commit: Bool) {
        let x = convert(event.locationInWindow, from: nil).x
        let usable = bounds.width - Self.knobSize
        let f = usable <= 0 ? 0 : min(1, max(0, (x - Self.knobSize / 2) / usable))
        value = minValue + Double(f) * (maxValue - minValue)
        needsLayout = true
        setAccessibilityValue(value)
        if commit, let action { _ = NSApp.sendAction(action, to: target, from: self) }
    }

    func applyChrome() {
        let c = HarnessChrome.current
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trackLayer.backgroundColor = c.surfaceElevated.cgColor
        fillLayer.backgroundColor = c.textPrimary.cgColor
        knob.backgroundColor = (isActive ? c.textPrimary : c.textSecondary).cgColor
        knob.borderWidth = 1
        knob.borderColor = c.border.cgColor
        HarnessDesign.applyShadow(.elevation1, to: knob)
        CATransaction.commit()
    }
}

// MARK: - Color swatch well

/// Rounded color swatch replacing `NSColorWell`. Click opens the shared `NSColorPanel`
/// (system, transient — the one place a system panel is unavoidable) and reports the new
/// color. Only the most-recently-clicked well owns the shared panel.
@MainActor
final class HarnessSwatchWell: NSControl {
    private let swatch = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }

    var color: NSColor = .gray {
        didSet { applyChrome() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        swatch.cornerCurve = .continuous
        swatch.borderWidth = 1
        layer?.addSublayer(swatch)
        setAccessibilityRole(.colorWell)
        setAccessibilityLabel("Color")
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        swatch.frame = bounds
        swatch.cornerRadius = HarnessDesign.Radius.control
        CATransaction.commit()
        applyChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        openPanel()
    }

    private func openPanel() {
        HarnessColorPanelCoordinator.shared.begin(owner: self, color: color)
    }

    /// Called by the shared coordinator when the singleton color panel changes while this
    /// well owns it. Routing through a never-deallocated coordinator (weak owner) avoids the
    /// dangling-target crash when a well is torn down with the panel still open.
    func applyPanelColor(_ newColor: NSColor) {
        color = newColor
        if let action { _ = NSApp.sendAction(action, to: target, from: self) }
    }

    func applyChrome() {
        let c = HarnessChrome.current
        CATransaction.begin(); CATransaction.setDisableActions(true)
        swatch.backgroundColor = color.cgColor
        swatch.borderColor = (isHovered ? c.focusRing : c.border).cgColor
        CATransaction.commit()
    }
}

/// Single permanent target/action for the shared `NSColorPanel`. The panel does NOT retain
/// its target, so pointing it at individual (deallocatable) swatch wells risks a dangling
/// target. This singleton lives for the process lifetime and forwards to the current owner
/// via a weak reference, so a torn-down well simply stops receiving updates.
@MainActor
private final class HarnessColorPanelCoordinator: NSObject {
    static let shared = HarnessColorPanelCoordinator()
    private weak var owner: HarnessSwatchWell?

    func begin(owner: HarnessSwatchWell, color: NSColor) {
        self.owner = owner
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(self)
        panel.setAction(#selector(panelChanged(_:)))
        panel.color = color
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func panelChanged(_ panel: NSColorPanel) {
        owner?.applyPanelColor(panel.color)
    }
}

// MARK: - Segmented control

/// Monochrome segmented control for small enums (cursor style, vi/emacs, 0/1, on/off).
/// Selected segment uses the `SettingsSidebarButton` selected treatment. Exposes a
/// popup-compatible shim (`titleOfSelectedItem` / `selectItem(withTitle:)`).
@MainActor
final class HarnessSegmented: NSControl {
    private var titles: [String] = []
    private var labels: [NSTextField] = []
    private var fills: [CALayer] = []
    private var selectedIndex = 0
    private var hoverIndex: Int? { didSet { applyChrome() } }
    private var trackingArea: NSTrackingArea?

    var selectedSegment: Int {
        get { selectedIndex }
        set {
            selectedIndex = max(0, min(max(0, titles.count - 1), newValue))
            applyChrome()
            setAccessibilityValue(titleOfSelectedItem)
        }
    }

    var titleOfSelectedItem: String? {
        titles.indices.contains(selectedIndex) ? titles[selectedIndex] : nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setAccessibilityRole(.radioGroup)
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setSegments(_ values: [String]) {
        titles = values
        for label in labels { label.removeFromSuperview() }
        for fill in fills { fill.removeFromSuperlayer() }
        fills = values.map { _ in
            let fill = CALayer(); fill.cornerCurve = .continuous; fill.cornerRadius = HarnessDesign.Radius.control - 2
            return fill
        }
        for fill in fills { layer?.addSublayer(fill) }
        labels = values.map { title in
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
            return label
        }
        if selectedIndex >= values.count { selectedIndex = 0 }
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyChrome()
        setAccessibilityValue(titleOfSelectedItem)
    }

    /// Popup-compatible shims so call sites swap type only.
    func selectItem(withTitle title: String) {
        if let i = titles.firstIndex(of: title) { selectedSegment = i }
    }

    override var intrinsicContentSize: NSSize {
        let perSegment: CGFloat = 72
        return NSSize(width: max(1, CGFloat(titles.count)) * perSegment, height: 26)
    }

    override func layout() {
        super.layout()
        guard !titles.isEmpty else { return }
        let w = bounds.width / CGFloat(titles.count)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in titles.indices {
            fills[i].frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height).insetBy(dx: 3, dy: 3)
        }
        CATransaction.commit()
        let textHeight: CGFloat = 16
        for i in titles.indices {
            labels[i].frame = NSRect(x: CGFloat(i) * w + 4, y: (bounds.height - textHeight) / 2,
                                     width: max(0, w - 8), height: textHeight)
        }
        applyChrome()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func index(at point: NSPoint) -> Int? {
        guard !titles.isEmpty, bounds.contains(point) else { return nil }
        let w = bounds.width / CGFloat(titles.count)
        return min(titles.count - 1, max(0, Int(point.x / w)))
    }

    override func mouseMoved(with event: NSEvent) { hoverIndex = index(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { hoverIndex = nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        selectedSegment = i
        if let action { _ = NSApp.sendAction(action, to: target, from: self) }
    }

    func applyChrome() {
        let c = HarnessChrome.current
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = c.surfaceElevated.cgColor
        layer?.borderColor = c.border.cgColor
        for (i, fill) in fills.enumerated() {
            if i == selectedIndex {
                fill.backgroundColor = c.rowSelectedFill.cgColor
            } else if i == hoverIndex {
                fill.backgroundColor = c.rowHoverFill.cgColor
            } else {
                fill.backgroundColor = NSColor.clear.cgColor
            }
        }
        CATransaction.commit()
        for (i, label) in labels.enumerated() {
            label.textColor = (i == selectedIndex ? c.textPrimary : c.textSecondary)
        }
    }
}

// MARK: - Select (searchable dropdown)

/// Themed dropdown replacing `NSPopUpButton` for long lists (the 490-theme catalog). Shows
/// the current value + chevron; click opens a searchable themed popover. Popup-compatible
/// shims keep call sites a type-swap.
@MainActor
final class HarnessSelect: NSControl {
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovered = false { didSet { applyChrome() } }
    private var items: [String] = []
    private var selected: String?
    private var popover: HarnessSelectPopover?

    var titleOfSelectedItem: String? { selected }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(chevron)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.popUpButton)
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Popup-compatible shims.
    func removeAllItems() { items.removeAll() }
    func addItem(withTitle title: String) { items.append(title) }
    func addItems(withTitles titles: [String]) { items.append(contentsOf: titles) }
    func selectItem(withTitle title: String) {
        guard items.contains(title) else { return }
        selected = title
        titleLabel.stringValue = title
        setAccessibilityValue(title)
    }

    override func layout() { super.layout(); applyChrome() }

    /// Leaving the window (e.g. the Settings window closing) must tear down any open popover
    /// so its child panel + event monitor can't outlive the control.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            popover?.dismiss()
            popover = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        showPopover()
    }

    private func showPopover() {
        guard let window else { return }
        popover?.dismiss() // never leave a previous popover (+ its event monitor) dangling
        let pop = HarnessSelectPopover(items: items, selected: selected) { [weak self] choice in
            guard let self else { return }
            self.selected = choice
            self.titleLabel.stringValue = choice
            self.setAccessibilityValue(choice)
            if let action { _ = NSApp.sendAction(action, to: self.target, from: self) }
        }
        popover = pop
        // The control's rect in screen coordinates; the popover hangs from its bottom edge.
        let screenRect = window.convertToScreen(convert(bounds, to: nil))
        pop.present(anchor: screenRect, width: max(bounds.width, 280), relativeTo: window)
    }

    func applyChrome() {
        let c = HarnessChrome.current
        layer?.backgroundColor = (isHovered ? c.rowHoverFill : c.surfaceElevated).cgColor
        layer?.borderColor = (isHovered ? c.borderStrong : c.border).cgColor
        titleLabel.textColor = c.textPrimary
        chevron.contentTintColor = c.textTertiary
    }
}

/// Borderless themed popover hosting a search field + scrollable filtered list, built on
/// `HarnessOverlayBackground`. Closes on selection, Esc, or resign-key.
@MainActor
final class HarnessSelectPopover: NSObject {
    private let allItems: [String]
    private let initialSelection: String?
    private let onPick: (String) -> Void
    private var panel: NSPanel?
    private let search = HarnessSearchField()
    private let stack = NSStackView()
    private var rows: [SelectRow] = []
    private var monitor: Any?

    init(items: [String], selected: String?, onPick: @escaping (String) -> Void) {
        self.allItems = items
        self.initialSelection = selected
        self.onPick = onPick
        super.init()
    }

    func present(anchor screenRect: NSRect, width: CGFloat, relativeTo parent: NSWindow) {
        let height: CGFloat = 360
        let overlay = HarnessOverlayBackground()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = "Search themes…"
        search.onChange = { [weak self] q in self?.filter(q) }
        search.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedStackHost()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false

        overlay.contentView.addSubview(search)
        overlay.contentView.addSubview(scroll)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: overlay.contentView.topAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: overlay.contentView.leadingAnchor, constant: 10),
            search.trailingAnchor.constraint(equalTo: overlay.contentView.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: overlay.contentView.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: overlay.contentView.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: overlay.contentView.bottomAnchor, constant: -8),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -2),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -2),
        ])

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Pin the overlay (Auto Layout) inside a plain content view that AppKit sizes to the
        // panel — assigning the overlay *as* the contentView while it has
        // `translatesAutoresizingMaskIntoConstraints = false` would leave it unsized.
        let container = NSView()
        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        // Hang from the control's bottom edge (AppKit screen coords: minY is the bottom).
        let frameY = screenRect.minY - 4 - height
        panel.setFrame(NSRect(x: screenRect.minX, y: frameY, width: width, height: height), display: true)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        rebuildRows(filter: "")
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.dismiss(); return nil } // Esc
            if event.type == .leftMouseDown, event.window !== panel { self.dismiss() }
            return event
        }
        DispatchQueue.main.async { panel.makeFirstResponder(self.search) }
    }

    private func filter(_ query: String) { rebuildRows(filter: query) }

    private func rebuildRows(filter query: String) {
        for r in rows { r.removeFromSuperview() }
        rows.removeAll()
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let filtered = q.isEmpty ? allItems : allItems.filter { $0.lowercased().contains(q) }
        for name in filtered.prefix(400) {
            let row = SelectRow(title: name, isSelected: name == initialSelection) { [weak self] in
                self?.onPick(name)
                self?.dismiss()
            }
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            rows.append(row)
        }
    }

    func dismiss() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
    }
}

@MainActor
private final class FlippedStackHost: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SelectRow: NSControl {
    private let label = NSTextField(labelWithString: "")
    private let onSelect: () -> Void
    private let isSelected: Bool
    private var isHovered = false { didSet { applyChrome() } }
    private var trackingArea: NSTrackingArea?

    init(title: String, isSelected: Bool, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        self.isSelected = isSelected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.pill
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 12.5, weight: isSelected ? .semibold : .regular)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        onSelect()
    }

    private func applyChrome() {
        let c = HarnessChrome.current
        if isSelected {
            layer?.backgroundColor = c.rowSelectedFill.cgColor
            label.textColor = c.textPrimary
        } else if isHovered {
            layer?.backgroundColor = c.rowHoverFill.cgColor
            label.textColor = c.textPrimary
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = c.textSecondary
        }
    }
}
