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
    /// Cheap guard: track one representative NSColor from the last-applied palette so
    /// layout()-driven applyChrome() calls are no-ops when the palette hasn't changed.
    /// NSColor uses isEqual: for `==`, which compares the underlying color values, so this
    /// correctly detects a theme change (a new palette with different colors) while skipping
    /// redundant redraws when layout fires on the same theme. Focus/state changes bypass this
    /// guard by calling applyChrome() directly (not via layout).
    private var lastChromeToken: NSColor?

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
        heightAnchor.constraint(greaterThanOrEqualToConstant: HarnessDesign.formControlHeight).isActive = true
        applyChrome()
    }

    convenience init(string: String) {
        self.init()
        stringValue = string
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { applyChrome() } }

    override func layout() {
        super.layout()
        // Skip the CALayer color writes when the palette hasn't changed since the last layout
        // pass — surfaceElevated is a stable sentinel for palette identity (HarnessChrome.update()
        // always builds a fresh NSColor). Focus/state paths call applyChrome() directly,
        // bypassing this guard, so they always apply.
        let token = HarnessChrome.current.surfaceElevated
        guard token != lastChromeToken else { return }
        lastChromeToken = token
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
        textColor = c.textPrimary; alphaValue = isEnabled ? 1 : 0.45
        if let placeholder = placeholderString {
            placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: c.textTertiary])
        }
    }
}

final class HarnessSecureTextFieldCell: NSSecureTextFieldCell {
    private func inset(_ rect: NSRect) -> NSRect {
        let height = cellSize(forBounds: rect).height
        return NSRect(x: rect.minX + 8, y: rect.midY - height / 2, width: max(0, rect.width - 16), height: height)
    }
    override func drawInterior(withFrame rect: NSRect, in view: NSView) { super.drawInterior(withFrame: inset(rect), in: view) }
    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: inset(rect), in: view, editor: editor, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: inset(rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }
}

@MainActor
final class HarnessSecureTextField: NSSecureTextField {
    private var focused = false
    override class var cellClass: AnyClass? { get { HarnessSecureTextFieldCell.self } set {} }
    init() {
        super.init(frame: .zero)
        isBezeled = false; isBordered = false; drawsBackground = false; focusRingType = .none
        font = .systemFont(ofSize: 12); wantsLayer = true
        layer?.cornerRadius = HarnessDesign.Radius.control; layer?.cornerCurve = .continuous; layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: HarnessDesign.formControlHeight).isActive = true
        applyChrome()
    }
    convenience init(string: String) { self.init(); stringValue = string }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isEnabled: Bool { didSet { applyChrome() } }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focused = true; applyChrome() }
        return accepted
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification); focused = false; applyChrome()
    }
    func applyChrome() {
        let c = HarnessChrome.current
        layer?.backgroundColor = c.surfaceElevated.cgColor
        layer?.borderColor = (focused ? c.focusRing : c.border).cgColor
        textColor = c.textPrimary; alphaValue = isEnabled ? 1 : 0.45
        if let placeholder = placeholderString {
            placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: c.textTertiary])
        }
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
    // Same layout-churn guard as HarnessTextField — skip redundant CALayer writes.
    private var lastChromeToken: NSColor?

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
            heightAnchor.constraint(equalToConstant: HarnessDesign.formControlHeight),
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
        let token = HarnessChrome.current.surfaceElevated
        guard token != lastChromeToken else { return }
        lastChromeToken = token
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
        layer?.borderColor = (window?.firstResponder === field.currentEditor() && field.currentEditor() != nil ? c.focusRing : c.border).cgColor
        magnifier.contentTintColor = c.textTertiary
        field.textColor = c.textPrimary
    }

    func controlTextDidBeginEditing(_ obj: Notification) { applyChrome() }
    func controlTextDidEndEditing(_ obj: Notification) { applyChrome() }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }
}

// MARK: - Keyboard focus

/// Keyboard-focus outline for the custom controls below: a 2pt ring in the theme's `focusRing`
/// color (the neutral interface accent) drawn just outside the control's shape.
/// Like AppKit's own buttons, these controls take focus only when Full Keyboard Access is on.
@MainActor
final class HarnessFocusRing {
    private let shape = CAShapeLayer()

    init(in host: CALayer?) {
        shape.fillColor = nil
        shape.lineWidth = 2
        shape.isHidden = true
        host?.addSublayer(shape)
    }

    static var controlsTakeFocus: Bool { NSApp?.isFullKeyboardAccessEnabled ?? false }

    func update(rect: NSRect, radius: CGFloat, visible: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.isHidden = !visible
        let outset: CGFloat = 3
        let ring = rect.insetBy(dx: -outset, dy: -outset)
        shape.path = CGPath(roundedRect: ring, cornerWidth: radius + outset, cornerHeight: radius + outset, transform: nil)
        shape.strokeColor = HarnessChrome.current.focusRing.withAlphaComponent(0.85).cgColor
        CATransaction.commit()
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
    private lazy var focusRing = HarnessFocusRing(in: layer)
    private var isFocused = false { didSet { needsLayout = true } }

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

    override var isEnabled: Bool { didSet { applyChrome() } }

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
        focusRing.update(rect: track.frame, radius: Self.trackHeight / 2, visible: isFocused)
        applyChrome()
    }

    override var acceptsFirstResponder: Bool { isEnabled && HarnessFocusRing.controlsTakeFocus }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }

    override func keyDown(with event: NSEvent) {
        // Space flips the switch, as it does a focused NSSwitch.
        if event.charactersIgnoringModifiers == " " { flip() } else { super.keyDown(with: event) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { flip(); return true }

    private func flip() {
        guard isEnabled else { return }
        state = state == .on ? .off : .on
        if let action { _ = NSApp.sendAction(action, to: target, from: self) }
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
        flip()
    }

    func applyChrome() {
        let c = HarnessChrome.current
        CATransaction.begin(); CATransaction.setDisableActions(true)
        alphaValue = isEnabled ? 1 : 0.45
        knob.shadowOpacity = 0
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
            if c.isDark {
                knob.backgroundColor = c.textSecondary.cgColor
            } else {
                // A white knob with a soft shadow on paper, like the system switch; the grey
                // ink knob read as a dark blob on a light canvas.
                knob.backgroundColor = NSColor.white.cgColor
                HarnessDesign.applyShadow(.elevation1, to: knob)
            }
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
    // Same layout-churn guard as HarnessTextField — skip redundant CALayer color writes.
    private var lastChromeToken: NSColor?
    private lazy var focusRing = HarnessFocusRing(in: layer)
    private var isFocused = false { didSet { needsLayout = true } }

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
        focusRing.update(rect: knob.frame, radius: Self.knobSize / 2, visible: isFocused)
        // Guard redundant color writes: isActive changes bypass this by calling applyChrome()
        // directly via the didSet above.
        let token = HarnessChrome.current.surfaceElevated
        guard token != lastChromeToken else { return }
        lastChromeToken = token
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

    override var acceptsFirstResponder: Bool { isEnabled && HarnessFocusRing.controlsTakeFocus }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }

    /// Arrow keys move a twentieth of the range per press and commit like a finished drag.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: step(-1)
        case 124, 126: step(1)
        default: super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformIncrement() -> Bool { step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { step(-1); return true }

    private func step(_ direction: Double) {
        guard isEnabled else { return }
        doubleValue = value + direction * (maxValue - minValue) / 20
        if let action { _ = NSApp.sendAction(action, to: target, from: self) }
        onCommit?()
    }

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
    private lazy var focusRing = HarnessFocusRing(in: layer)
    private var isFocused = false { didSet { needsLayout = true } }

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
        focusRing.update(rect: bounds, radius: HarnessDesign.Radius.control, visible: isFocused)
        applyChrome()
    }

    override var acceptsFirstResponder: Bool { isEnabled && HarnessFocusRing.controlsTakeFocus }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 { openPanel() } else { super.keyDown(with: event) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { openPanel(); return true }

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
    enum Style { case standard, tabs }
    var style: Style = .standard {
        didSet { needsLayout = true; applyChrome() }
    }
    override var font: NSFont? {
        didSet {
            for label in labels { label.font = font ?? .systemFont(ofSize: 11.5, weight: .medium) }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private var titles: [String] = []
    private var labels: [NSTextField] = []
    private var fills: [CALayer] = []
    private var selectedIndex = 0
    private var hoverIndex: Int? { didSet { applyChrome() } }
    private var trackingArea: NSTrackingArea?
    // Same layout-churn guard as HarnessTextField — skip redundant CALayer color writes.
    private var lastChromeToken: NSColor?
    private lazy var focusRing = HarnessFocusRing(in: layer)
    private var isFocused = false { didSet { needsLayout = true } }

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
            label.font = font ?? .systemFont(ofSize: 11.5, weight: .medium)
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

    /// Equal-width segments sized to the longest title, so no label ever truncates.
    override var intrinsicContentSize: NSSize {
        let widest = labels.map { ceil($0.intrinsicContentSize.width) }.max() ?? 0
        let perSegment = max(56, widest + 22)
        return NSSize(width: max(1, CGFloat(titles.count)) * perSegment, height: 26)
    }

    override func layout() {
        super.layout()
        guard !titles.isEmpty else { return }
        let w = bounds.width / CGFloat(titles.count)
        layer?.cornerRadius = style == .tabs ? bounds.height / 2 : HarnessDesign.Radius.control
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for i in titles.indices {
            fills[i].frame = NSRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height).insetBy(dx: 3, dy: 3)
            fills[i].cornerRadius = style == .tabs ? fills[i].bounds.height / 2 : HarnessDesign.Radius.control - 2
        }
        CATransaction.commit()
        let textHeight: CGFloat = 16
        for i in titles.indices {
            labels[i].frame = NSRect(x: CGFloat(i) * w + 4, y: (bounds.height - textHeight) / 2,
                                     width: max(0, w - 8), height: textHeight)
        }
        focusRing.update(rect: bounds, radius: layer?.cornerRadius ?? HarnessDesign.Radius.control, visible: isFocused)
        // Hover/selection changes bypass this guard via their own applyChrome() calls.
        let token = HarnessChrome.current.surfaceElevated
        guard token != lastChromeToken else { return }
        lastChromeToken = token
        applyChrome()
    }

    override var acceptsFirstResponder: Bool { isEnabled && HarnessFocusRing.controlsTakeFocus }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }

    /// ← / → move the selection, the way a focused NSSegmentedControl does.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: move(-1)
        case 124: move(1)
        default: super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformIncrement() -> Bool { move(1); return true }
    override func accessibilityPerformDecrement() -> Bool { move(-1); return true }

    private func move(_ delta: Int) {
        let next = selectedIndex + delta
        guard isEnabled, titles.indices.contains(next) else { return }
        selectedSegment = next
        if let action { _ = NSApp.sendAction(action, to: target, from: self) }
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
        guard isEnabled, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        selectedSegment = i
        if let action { _ = NSApp.sendAction(action, to: target, from: self) }
    }

    func applyChrome() {
        let c = HarnessChrome.current
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = c.surfaceElevated.cgColor
        layer?.borderColor = c.border.cgColor
        for (i, fill) in fills.enumerated() {
            let activeTab = style == .tabs && i == selectedIndex
            fill.borderWidth = activeTab ? 1 : 0
            fill.borderColor = activeTab ? c.textPrimary.withAlphaComponent(HarnessDesign.activeGlassBorderAlpha(isDark: c.isDark)).cgColor : nil
            HarnessDesign.applyShadow(activeTab && c.isDark ? .elevation1 : .none, to: fill)
            if i == selectedIndex {
                fill.backgroundColor = (style == .tabs ? HarnessDesign.activeTabFill : c.rowSelectedFill).cgColor
            } else if i == hoverIndex {
                fill.backgroundColor = c.rowHoverFill.cgColor
            } else {
                fill.backgroundColor = NSColor.clear.cgColor
            }
        }
        CATransaction.commit()
        for (i, label) in labels.enumerated() {
            label.textColor = (i == selectedIndex ? (style == .tabs ? c.activePillLabel : c.textPrimary) : c.textSecondary)
        }
        alphaValue = isEnabled ? 1 : 0.45
    }
}

// MARK: - Select (searchable dropdown)

/// Themed dropdown replacing `NSPopUpButton` for long lists such as the theme catalog. Shows
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
    // Same layout-churn guard as HarnessTextField — skip redundant CALayer color writes.
    private var lastChromeToken: NSColor?
    private lazy var focusRing = HarnessFocusRing(in: layer)
    private var isFocused = false { didSet { needsLayout = true } }

    var titleOfSelectedItem: String? { selected }
    var emptyTitle = "No options available" { didSet { applyChrome() } }
    var onSelection: ((String) -> Void)?
    /// Placeholder for the popover's filter field.
    var searchPlaceholder = "Search"
    /// The leading items (the featured themes) sit above a hairline when the list is unfiltered.
    var featuredCount = 0

    override var isEnabled: Bool { didSet { applyChrome() } }

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
            heightAnchor.constraint(equalToConstant: HarnessDesign.formControlHeight),
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
    var indexOfSelectedItem: Int { selected.flatMap { items.firstIndex(of: $0) } ?? -1 }
    func selectItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        selectItem(withTitle: items[index])
    }
    func removeAllItems() { items.removeAll(); selected = nil; applyChrome(); setAccessibilityValue(emptyTitle) }
    func addItems(withTitles titles: [String]) {
        items.append(contentsOf: titles)
        if selected == nil, let first = items.first { selectItem(withTitle: first) }
    }
    func selectItem(withTitle title: String) {
        guard items.contains(title) else { return }
        selected = title
        titleLabel.stringValue = title
        setAccessibilityValue(title)
        applyChrome()
    }

    override func layout() {
        super.layout()
        focusRing.update(rect: bounds, radius: HarnessDesign.Radius.control, visible: isFocused)
        // Hover changes bypass this guard via isHovered.didSet → applyChrome().
        let token = HarnessChrome.current.surfaceElevated
        guard token != lastChromeToken else { return }
        lastChromeToken = token
        applyChrome()
    }

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

    override var acceptsFirstResponder: Bool { isEnabled && HarnessFocusRing.controlsTakeFocus }
    override func becomeFirstResponder() -> Bool { isFocused = true; return true }
    override func resignFirstResponder() -> Bool { isFocused = false; return true }

    override func keyDown(with event: NSEvent) {
        // Space, Return, or ↓ opens the list, like a focused pop-up button.
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 || event.keyCode == 125 {
            showPopover()
        } else {
            super.keyDown(with: event)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { showPopover(); return true }

    private func showPopover() {
        guard let window, isEnabled, !items.isEmpty else { return }
        popover?.dismiss() // never leave a previous popover (+ its event monitor) dangling
        let pop = HarnessSelectPopover(
            items: items, selected: selected, placeholder: searchPlaceholder, featuredCount: featuredCount
        ) { [weak self] choice in
            guard let self else { return }
            self.selected = choice
            self.titleLabel.stringValue = choice
            self.setAccessibilityValue(choice)
            self.applyChrome()
            self.onSelection?(choice)
            if let action { _ = NSApp.sendAction(action, to: self.target, from: self) }
        }
        // Release the popover (and its `allItems` array) immediately when it closes, rather
        // than holding it until the next showPopover call.  The [weak self] guard in the
        // closure prevents a use-after-nil if the control itself is deallocated first.
        pop.onDismiss = { [weak self] in
            self?.popover = nil
        }
        popover = pop
        // The control's rect in screen coordinates; the popover hangs from its bottom edge.
        let screenRect = window.convertToScreen(convert(bounds, to: nil))
        pop.present(anchor: screenRect, width: max(bounds.width, 280), relativeTo: window)
    }

    func applyChrome() {
        let c = HarnessChrome.current
        alphaValue = isEnabled ? 1 : 0.45
        layer?.backgroundColor = (isHovered ? c.rowHoverFill : c.surfaceElevated).cgColor
        layer?.borderColor = (isHovered ? c.borderStrong : c.border).cgColor
        titleLabel.stringValue = selected ?? emptyTitle
        titleLabel.textColor = selected == nil ? c.textTertiary : c.textPrimary
        chevron.contentTintColor = c.textTertiary
    }
}

/// Borderless themed popover hosting a search field + scrollable filtered list, built on
/// `HarnessOverlayBackground`. Closes on selection, Esc, or resign-key.
@MainActor
final class HarnessSelectPopover: NSObject {
    private let allItems: [String]
    private let initialSelection: String?
    private let placeholder: String
    private let featuredCount: Int
    private let onPick: (String) -> Void
    /// Called once, after the panel + event monitor have been fully torn down.
    /// `HarnessSelect` uses this to nil its own `popover` reference so the
    /// `allItems` array is released immediately on dismiss rather than held until the
    /// next popover open.  Not set by default — callers that don't need the callback
    /// can skip it.
    var onDismiss: (() -> Void)?
    private var panel: NSPanel?
    private let search = HarnessSearchField()
    private let stack = NSStackView()
    private var rows: [NSView] = []
    private var monitor: Any?

    init(items: [String], selected: String?, placeholder: String, featuredCount: Int, onPick: @escaping (String) -> Void) {
        self.allItems = items
        self.initialSelection = selected
        self.placeholder = placeholder
        self.featuredCount = featuredCount
        self.onPick = onPick
        super.init()
    }

    func present(anchor screenRect: NSRect, width: CGFloat, relativeTo parent: NSWindow) {
        let height: CGFloat = 360
        let overlay = HarnessOverlayBackground()
        overlay.translatesAutoresizingMaskIntoConstraints = false

        search.placeholderString = placeholder
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

        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
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
        for (index, name) in filtered.prefix(400).enumerated() {
            if q.isEmpty, index > 0, index == featuredCount {
                let rule = HarnessDesign.divider()
                stack.addArrangedSubview(rule)
                rule.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 8).isActive = true
                rule.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -8).isActive = true
                rows.append(rule)
            }
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
        // Notify the owner so it can nil its own reference to this popover.  This releases
        // the `allItems` array immediately rather than retaining it
        // until the next popover open or window close.  The callback is invoked after all
        // teardown so the owner cannot re-enter dismiss() via its own cleanup.
        onDismiss?()
    }
}

@MainActor
final class FlippedStackHost: NSView {
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
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
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

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onSelect(); return true }

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
