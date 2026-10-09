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

    /// A determinate percent while working: the program's OSC 7501 mark, else OSC 9;4.
    @MainActor
    static func progress(of tab: Tab) -> Int? {
        if let percent = tab.programMark?.progress { return max(0, min(100, percent)) }
        return tab.rootPane.allSurfaceIDs().lazy.compactMap { SurfaceProgressTracker.shared.progressPercent($0) }.first
    }
}

/// Trailing status mark on a tab: a spinner while working (a filling ring when the program
/// reports a percent), a hand when it needs you, a check when done, a cross on error.
/// Reduce Motion shows a still arc.
@MainActor
final class TabStatusView: NSView {
    private let arc = CAShapeLayer()
    /// The faint full ring behind a percent.
    private let track = CAShapeLayer()
    private let symbol = NSImageView()
    private(set) var activity: TabActivity = .none
    private var progress: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        arc.fillColor = NSColor.clear.cgColor
        arc.lineWidth = 1.5
        arc.lineCap = .round
        track.fillColor = NSColor.clear.cgColor
        track.lineWidth = 1.5
        layer?.addSublayer(track)
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
        layoutArc()
    }

    private func layoutArc() {
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        arc.frame = bounds
        track.frame = bounds
        let center = CGPoint(x: inset.midX, y: inset.midY)
        let radius = inset.width / 2
        let path = CGMutablePath()
        if let progress {
            // Clockwise from twelve o'clock, filled to the percent.
            path.addArc(center: center, radius: radius, startAngle: .pi / 2,
                        endAngle: .pi / 2 - 2 * .pi * CGFloat(max(progress, 3)) / 100, clockwise: true)
            let ring = CGMutablePath()
            ring.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            track.path = ring
        } else {
            path.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 1.5, clockwise: false)
            track.path = nil
        }
        arc.path = path
    }

    func apply(_ activity: TabActivity, tint: NSColor, progress: Int? = nil) {
        self.activity = activity
        let progress = activity == .working ? progress : nil
        if progress != self.progress {
            self.progress = progress
            layoutArc()
        }
        track.strokeColor = tint.withAlphaComponent(0.25).cgColor
        track.isHidden = progress == nil
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
        toolTip = progress.map { "Working · \($0)%" } ?? Self.label(activity)
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
        let spinning = activity == .working && progress == nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !spinning {
            arc.removeAnimation(forKey: "spin")
            return
        }
        guard arc.animation(forKey: "spin") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.8
        spin.repeatCount = .infinity
        arc.add(spin, forKey: "spin")
    }
}
