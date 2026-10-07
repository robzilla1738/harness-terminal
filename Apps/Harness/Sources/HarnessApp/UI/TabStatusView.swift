import AppKit
import HarnessCore

/// What a tab is doing, from its OSC 7501 mark, then the agent detector.
enum TabActivity: Equatable {
    case none, working, blocked, done, error

    @MainActor
    static func of(_ tab: Tab) -> TabActivity {
        if let mark = tab.programMark {
            switch mark.attention {
            case .working: return .working
            case .blocked: return .blocked
            case .done: return .done
            case .error: return .error
            }
        }
        if tab.status == .waiting { return .blocked }
        if tab.rootPane.allSurfaceIDs().contains(where: { SurfaceProgressTracker.shared.isActive($0) }) {
            return .working
        }
        return tab.agent?.activity == .working ? .working : .none
    }
}

/// Trailing status mark on a tab: a spinner while working, a hand when it needs you,
/// a check when done, a cross on error. Reduce Motion shows a still arc.
@MainActor
final class TabStatusView: NSView {
    private let arc = CAShapeLayer()
    private let symbol = NSImageView()
    private(set) var activity: TabActivity = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arc.fillColor = NSColor.clear.cgColor
        arc.lineWidth = 1.5
        arc.lineCap = .round
        layer?.addSublayer(arc)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.translatesAutoresizingMaskIntoConstraints = false
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalTo: widthAnchor),
            symbol.heightAnchor.constraint(equalTo: heightAnchor),
        ])
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(reduceMotionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 12) }

    override func layout() {
        super.layout()
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        arc.frame = bounds
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2,
                    startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
        arc.path = path
    }

    func apply(_ activity: TabActivity, tint: NSColor) {
        self.activity = activity
        let c = HarnessChrome.current
        isHidden = activity == .none
        arc.isHidden = activity != .working
        symbol.isHidden = activity == .working || activity == .none
        arc.strokeColor = tint.cgColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        switch activity {
        case .none, .working:
            break
        case .blocked:
            symbol.image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Needs you")?.withSymbolConfiguration(config)
            symbol.contentTintColor = c.attention
        case .done:
            symbol.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")?.withSymbolConfiguration(config)
            symbol.contentTintColor = c.success
        case .error:
            symbol.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Error")?.withSymbolConfiguration(config)
            symbol.contentTintColor = c.danger
        }
        toolTip = Self.label(activity)
        updateSpin()
    }

    static func label(_ activity: TabActivity) -> String? {
        switch activity {
        case .none: return nil
        case .working: return "Working"
        case .blocked: return "Needs you"
        case .done: return "Done"
        case .error: return "Error"
        }
    }

    @objc private func reduceMotionChanged() { updateSpin() }

    private func updateSpin() {
        let spinning = activity == .working && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !spinning {
            arc.removeAnimation(forKey: "spin")
            return
        }
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 0.9
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
}
