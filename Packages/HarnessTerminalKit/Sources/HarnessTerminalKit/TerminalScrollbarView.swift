import AppKit

/// AppKit owns tracking, thumb geometry, accessibility, and the system's track-click behavior.
/// This overlay is a sibling of the Metal surface, so its gestures never select terminal text.
final class TerminalScrollbarView: NSScroller {
    static let stripWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    var onScroll: ((Int) -> Void)?
    private var totalLines = 0
    private var visibleRows = 0
    private var hideWork: DispatchWorkItem?
    private var tracking = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.stripWidth, height: 100))
        translatesAutoresizingMaskIntoConstraints = false
        scrollerStyle = NSScroller.preferredScrollerStyle
        target = self
        action = #selector(scrollChanged)
        isHidden = true
        setAccessibilityLabel("Terminal scrollback")
        NotificationCenter.default.addObserver(self, selector: #selector(styleChanged),
            name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyColor(_ color: NSColor) {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        knobStyle = rgb.brightnessComponent > 0.5 ? .light : .dark
    }

    func show(topLine: Int, totalLines: Int, visibleRows: Int, fadeOutAfter: TimeInterval = 0.9) {
        self.totalLines = totalLines
        self.visibleRows = visibleRows
        guard totalLines > visibleRows, visibleRows > 0 else { hideNow(); return }
        doubleValue = min(1, max(0, Double(topLine) / Double(totalLines - visibleRows)))
        knobProportion = CGFloat(visibleRows) / CGFloat(totalLines)
        hideWork?.cancel()
        isEnabled = true
        isHidden = false
        alphaValue = 1
        guard scrollerStyle == .overlay, !tracking else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.tracking else { return }
            self.isHidden = true
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOutAfter, execute: work)
    }

    func hideNow() {
        hideWork?.cancel()
        hideWork = nil
        isEnabled = false
        isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        tracking = true
        hideWork?.cancel()
        super.mouseDown(with: event)
        tracking = false
        show(topLine: topLine, totalLines: totalLines, visibleRows: visibleRows)
    }

    private var topLine: Int {
        Int((doubleValue * Double(max(0, totalLines - visibleRows))).rounded())
    }

    @objc private func scrollChanged() {
        var line = topLine
        switch hitPart {
        case .decrementLine: line -= 1
        case .incrementLine: line += 1
        case .decrementPage: line -= max(1, visibleRows - 1)
        case .incrementPage: line += max(1, visibleRows - 1)
        default: break
        }
        onScroll?(min(max(0, totalLines - visibleRows), max(0, line)))
    }

    @objc private func styleChanged() {
        scrollerStyle = NSScroller.preferredScrollerStyle
        show(topLine: topLine, totalLines: totalLines, visibleRows: visibleRows)
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
