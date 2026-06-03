import AppKit

/// Thin draggable strip above the tab bar, in the window's `.fullSizeContentView` titlebar
/// region. Two jobs: (1) give the user a grab area to move the window (and breathing room above
/// the tab pills so dragging a tab never fights a window-move), and (2) show the active tab's
/// directory the way Ghostty does — a folder glyph + `· name`, centered. Purely chrome: clicks
/// fall through to window-drag (the traffic-light buttons live above this in the frame view).
@MainActor
final class WindowTitleStripView: NSView {
    private let folderIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    /// Base left padding for the readout; the traffic-light inset is added on top while
    /// the sidebar is collapsed (the lights then sit over the strip's left edge).
    private var stackLeading: NSLayoutConstraint?
    private let basePadding: CGFloat = 14

    /// Height: enough to seat the path readout and clear the macOS traffic lights so the tab
    /// strip below never overlaps them (which is why the tab bar no longer needs a leading inset).
    static let height: CGFloat = 30

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        folderIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")?
            .withSymbolConfiguration(config)
        folderIcon.imageScaling = .scaleProportionallyUpOrDown
        folderIcon.translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .left
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(folderIcon)
        stack.addArrangedSubview(label)
        addSubview(stack)

        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: basePadding)
        stackLeading = leading
        NSLayoutConstraint.activate([
            leading,
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            folderIcon.widthAnchor.constraint(equalToConstant: 16),
            folderIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A drag anywhere on the strip moves the window (matches the empty tab-bar background).
    override var mouseDownCanMoveWindow: Bool { true }

    /// Shift the readout right of the macOS traffic lights while the sidebar is collapsed
    /// (0 = sidebar visible; ~72 = collapsed). Driven by `MainSplitViewController` during
    /// the toggle so it slides in lockstep with the divider.
    func setLeadingInset(_ inset: CGFloat) {
        stackLeading?.constant = basePadding + inset
    }

    /// Show the active tab's directory as `· basename`, Ghostty-style. Empty cwd hides the readout
    /// (the strip stays as a drag handle).
    func setPath(_ cwd: String) {
        let name = HarnessDesign.pathDisplayName(cwd)
        let hasPath = !name.isEmpty
        folderIcon.isHidden = !hasPath
        label.isHidden = !hasPath
        label.stringValue = hasPath ? "·  \(name)" : ""
        toolTip = hasPath ? HarnessDesign.shortenPath(cwd) : nil
    }

    func applyColors() {
        // Same vibrancy+tint backdrop as the tab bar below, so the strip reads as one
        // continuous chrome surface instead of a transparent hole in the titlebar region.
        HarnessDesign.applyTabBarChrome(to: self)
        let c = HarnessDesign.chrome
        folderIcon.contentTintColor = c.textSecondary
        label.textColor = c.textSecondary
    }
}
