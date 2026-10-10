import AppKit
import HarnessCore

/// Shared chrome for auxiliary tools, using the same palette as the terminal and Settings.
@MainActor
final class HarnessToolPage: NSView {
    private let heading: NSTextField
    private let subtitle: NSTextField
    private let icon: NSImageView
    private let body: NSView

    static func install(in window: NSWindow, title: String, subtitle: String, symbol: String, content: NSView) {
        content.removeFromSuperview()
        let page = HarnessToolPage(title: title, subtitle: subtitle, symbol: symbol, content: content)
        window.contentView = page
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        page.applyChrome()
    }

    init(title: String, subtitle: String, symbol: String, content: NSView) {
        heading = NSTextField(labelWithString: title)
        self.subtitle = NSTextField(wrappingLabelWithString: subtitle)
        icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        body = content
        super.init(frame: .zero)
        wantsLayer = true
        heading.font = .systemFont(ofSize: 21, weight: .semibold)
        self.subtitle.font = .systemFont(ofSize: 12)
        let titles = NSStackView(views: [heading, self.subtitle])
        titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 5
        let header = NSStackView(views: [icon, titles])
        header.spacing = HarnessDesign.Spacing.lg; header.alignment = .centerY
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.borderType = .noBorder
        let document = ToolDocumentView()
        scroll.documentView = document
        document.addSubview(content)
        for view in [header, scroll, document, content] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(header); addSubview(scroll)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged(_:)), name: NotificationBus.shared.snapshotChanged, object: nil)
        applyChrome()
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyChrome() }
    @objc private func themeChanged(_ notification: Notification) {
        guard notification.userInfo?["chromeChanged"] as? Bool == true else { return }
        applyChrome()
    }
    private func applyChrome() {
        let chrome = HarnessChrome.current
        layer?.backgroundColor = chrome.terminalBackground.cgColor
        window?.backgroundColor = chrome.terminalBackground
        window?.appearance = NSAppearance(named: chrome.isDark ? .darkAqua : .aqua)
        heading.textColor = chrome.textPrimary; subtitle.textColor = chrome.textSecondary; icon.contentTintColor = chrome.textSecondary
        Self.style(body)
    }
    static func style(_ view: NSView) {
        let c = HarnessChrome.current
        switch view {
        case let card as ToolSectionView: card.applyChrome()
        case let field as HarnessTextField: field.applyChrome()
        case let field as HarnessSecureTextField: field.applyChrome()
        case let toggle as HarnessToggle: toggle.applyChrome(); return
        case let select as HarnessSelect: select.applyChrome(); return
        case let segments as HarnessSegmented: segments.applyChrome(); return
        case let button as HarnessPillButton: button.applyChrome(); return
        case let text as NSTextView:
            text.backgroundColor = text.isEditable ? c.surfaceElevated : c.sidebarBackground; text.textColor = c.textPrimary
            text.insertionPointColor = c.accent; text.textContainerInset = NSSize(width: 12, height: 12)
            text.selectedTextAttributes = [.backgroundColor: c.activePillFill, .foregroundColor: c.activePillLabel]
        case let field as NSSecureTextField:
            field.isBezeled = false; field.isBordered = false; field.drawsBackground = false
            field.wantsLayer = true; field.layer?.cornerRadius = HarnessDesign.Radius.control
            field.layer?.borderWidth = 1; field.layer?.borderColor = c.border.cgColor
            field.layer?.backgroundColor = c.surfaceElevated.cgColor; field.textColor = c.textPrimary
            field.font = .systemFont(ofSize: 12)
            if let placeholder = field.placeholderString {
                field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.foregroundColor: c.textTertiary])
            }
        case let field as NSTextField:
            // Explicit color samples keep their foreground/background pairing.
            if !field.drawsBackground || field.isEditable { field.textColor = c.textPrimary }
            if field.isEditable { field.backgroundColor = c.sidebarBackground }
        case let table as NSTableView:
            table.backgroundColor = c.sidebarBackground; table.rowHeight = max(32, table.rowHeight)
            table.intercellSpacing = NSSize(width: 12, height: 6)
            table.gridStyleMask = []; table.usesAlternatingRowBackgroundColors = false
            table.style = .inset
        case let scroll as NSScrollView:
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.wantsLayer = true; scroll.layer?.cornerRadius = HarnessDesign.Radius.card
            scroll.layer?.cornerCurve = .continuous; scroll.layer?.borderWidth = 1; scroll.layer?.borderColor = c.border.cgColor
        case let button as NSButton:
            button.font = HarnessDesign.Typography.sidebarLabel
            button.contentTintColor = c.textPrimary
        default: break
        }
        for child in view.subviews { style(child) }
    }
    @discardableResult
    static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        HarnessToolDialog(alert: alert).run()
    }
    static func button(_ title: String, target: AnyObject?, action: Selector?, primary: Bool = false) -> HarnessPillButton {
        let button = HarnessPillButton(title: title, kind: primary ? .primary : .secondary)
        button.target = target; button.action = action; button.setAccessibilityLabel(title)
        return button
    }
    /// Short rows keep named actions readable at a tool window's minimum width.
    static func actionRows(_ actions: [NSView]) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        for start in stride(from: 0, to: actions.count, by: 3) {
            let row = NSStackView(views: Array(actions[start..<min(start + 3, actions.count)]))
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        return stack
    }
    static func field(_ title: String, control: NSView, hint: String? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title); label.font = HarnessDesign.Typography.sidebarLabel
        let row = NSStackView(views: [label, control]); row.orientation = .vertical; row.alignment = .leading; row.spacing = 6
        control.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        if let hint { let note = NSTextField(wrappingLabelWithString: hint); note.font = .systemFont(ofSize: 11); row.addArrangedSubview(note); note.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true }
        return row
    }
    static func group(_ root: NSStackView, title: String, views: [NSView], collapsible: Bool = false) {
        guard let index = views.compactMap({ root.arrangedSubviews.firstIndex(of: $0) }).min() else { return }
        for view in views { root.removeArrangedSubview(view); view.removeFromSuperview() }
        let section = ToolSectionView(title, views: views, collapsible: collapsible)
        root.insertArrangedSubview(section, at: index)
        section.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -(root.edgeInsets.left + root.edgeInsets.right)).isActive = true
        root.spacing = HarnessDesign.Spacing.xl
    }
}

private final class ToolDocumentView: NSView { override var isFlipped: Bool { true } }

@MainActor
final class ToolSectionView: NSStackView {
    private var disclosure: NSButton?
    private var disclosureTitle = ""
    init(_ title: String, views: [NSView], collapsible: Bool = false) {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = HarnessDesign.Spacing.lg
        edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        if collapsible {
            disclosureTitle = title
            let button = NSButton(title: title, target: self, action: #selector(toggleDetails))
            button.isBordered = false; button.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            button.imagePosition = .imageLeading; button.setAccessibilityLabel("Show " + title)
            disclosure = button; addArrangedSubview(button)
        } else {
            let heading = NSTextField(labelWithString: title); heading.font = HarnessDesign.Typography.settingsHeading
            addArrangedSubview(heading)
        }
        for view in views { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor, constant: -32).isActive = true; view.isHidden = collapsible }
        wantsLayer = true; layer?.cornerRadius = HarnessDesign.Radius.card; layer?.cornerCurve = .continuous; layer?.borderWidth = 1
        applyChrome()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func toggleDetails() {
        guard let disclosure else { return }
        let expanded = disclosure.state != .on
        disclosure.state = expanded ? .on : .off
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        disclosure.setAccessibilityLabel((expanded ? "Hide " : "Show ") + disclosureTitle)
        for view in arrangedSubviews where view !== disclosure { view.isHidden = !expanded }
    }
    func applyChrome() { layer?.backgroundColor = HarnessChrome.current.surfaceElevated.cgColor; layer?.borderColor = HarnessChrome.current.border.cgColor }
}

/// App-owned modal chrome keeps long configuration forms readable and actions fixed.
@MainActor
private final class HarnessToolDialog: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private var cancelResponse = NSApplication.ModalResponse.abort

    init(alert: NSAlert) {
        let accessory = alert.accessoryView
        accessory?.layoutSubtreeIfNeeded()
        let fitting = accessory?.fittingSize ?? .zero
        let contentWidth = max(460, fitting.width, accessory?.frame.width ?? 0)
        let buttonWidths = alert.buttons.map { ($0.title as NSString).size(withAttributes: [.font: HarnessDesign.Typography.sidebarLabel]).width + 32 }
        let actionsWidth = buttonWidths.reduce(0, +) + CGFloat(max(0, buttonWidths.count - 1)) * 10 + 48
        let width = max(contentWidth + 64, actionsWidth)
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let explanationHeight = (alert.informativeText as NSString).boundingRect(
            with: NSSize(width: width - 48, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).height
        let height = min(screenHeight - 60, max(300, max(fitting.height, accessory?.frame.height ?? 0) + ceil(explanationHeight) + 200))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = alert.messageText
        panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: width, height: min(420, height))
        let body = NSStackView()
        body.orientation = .vertical; body.alignment = .leading
        body.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)
        if !alert.informativeText.isEmpty {
            let explanation = NSTextField(wrappingLabelWithString: alert.informativeText)
            explanation.font = .systemFont(ofSize: 12)
            body.addArrangedSubview(explanation)
            explanation.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            body.spacing = 16
        }
        if let accessory {
            alert.accessoryView = nil
            accessory.removeFromSuperview()
            body.addArrangedSubview(accessory)
            accessory.widthAnchor.constraint(equalTo: body.widthAnchor, constant: -32).isActive = true
            if !(accessory is NSStackView) {
                accessory.heightAnchor.constraint(greaterThanOrEqualToConstant: max(28, fitting.height, accessory.frame.height)).isActive = true
            }
        }
        let page = HarnessToolPage(title: alert.messageText, subtitle: "",
                                   symbol: alert.alertStyle == .critical ? "exclamationmark.triangle" : "slider.horizontal.3", content: body)
        let actions = NSStackView()
        actions.orientation = .horizontal; actions.spacing = 10
        let sourceButtons = alert.buttons.isEmpty ? [NSButton(title: "OK", target: nil, action: nil)] : alert.buttons
        for (index, source) in sourceButtons.enumerated().reversed() {
            let button = HarnessToolPage.button(source.title, target: self, action: #selector(choose(_:)), primary: index == 0)
            button.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
            button.isEnabled = source.isEnabled
            if index == 0 { button.keyEquivalent = "\r" }
            if source.title.lowercased() == "cancel" {
                button.keyEquivalent = "\u{1b}"
                cancelResponse = .init(rawValue: button.tag)
            }
            actions.addArrangedSubview(button)
        }
        let container = NSView()
        panel.contentView = container
        for view in [page, actions] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            page.topAnchor.constraint(equalTo: container.topAnchor),
            page.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            actions.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20)
        ])
        panel.backgroundColor = HarnessChrome.current.terminalBackground
        panel.appearance = NSAppearance(named: HarnessChrome.current.isDark ? .darkAqua : .aqua)
    }
    func run() -> NSApplication.ModalResponse {
        panel.center(); panel.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response
    }
    @objc private func choose(_ sender: NSButton) { NSApp.stopModal(withCode: .init(rawValue: sender.tag)) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal(withCode: cancelResponse)
        return false
    }
}
