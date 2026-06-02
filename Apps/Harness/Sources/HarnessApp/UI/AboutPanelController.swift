import AppKit

@MainActor
enum AboutPanelController {
    private static var panel: NSPanel?

    static func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private static func makePanel() -> NSPanel {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let cliPath = CLIInstaller.installedCLIPath.path

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "About Harness"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = false
        panel.isRestorable = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let icon = HarnessDesign.brandLogo() {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 96).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 96).isActive = true
            stack.addArrangedSubview(iconView)
            stack.setCustomSpacing(14, after: iconView)
        }

        let title = NSTextField(labelWithString: "Harness")
        title.font = .systemFont(ofSize: 24, weight: .bold)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(2, after: title)

        let versionLabel = NSTextField(labelWithString: "Version \(version) · build \(build)")
        versionLabel.font = .systemFont(ofSize: 11.5)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)
        stack.setCustomSpacing(14, after: versionLabel)

        let tagline = NSTextField(wrappingLabelWithString: "A native macOS terminal for AI agents and dev sessions.\nGPU-rendered by Harness's own terminal engine.")
        tagline.alignment = .center
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(tagline)
        stack.setCustomSpacing(18, after: tagline)

        let cliCaption = NSTextField(labelWithString: "harness-cli installed at")
        cliCaption.font = .systemFont(ofSize: 10.5, weight: .semibold)
        cliCaption.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(cliCaption)
        stack.setCustomSpacing(2, after: cliCaption)

        let cliLabel = NSTextField(wrappingLabelWithString: cliPath)
        cliLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        cliLabel.textColor = .labelColor
        cliLabel.alignment = .center
        cliLabel.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(cliLabel)
        stack.setCustomSpacing(18, after: cliLabel)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10

        // Monochrome pills (never the system-blue default button). The GitHub link is
        // deliberately NOT a `keyEquivalent = "\r"` default button — that is what macOS
        // auto-tints with the accent color.
        let copyCLI = HarnessPillButton(title: "Copy CLI Path", kind: .secondary)
        copyCLI.target = LinkHandler.shared
        copyCLI.action = #selector(LinkHandler.copyCLIPath)

        let link = HarnessPillButton(title: "Open on GitHub", kind: .secondary)
        link.target = LinkHandler.shared
        link.action = #selector(LinkHandler.openRepo)

        buttons.addArrangedSubview(copyCLI)
        buttons.addArrangedSubview(link)
        stack.addArrangedSubview(buttons)

        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .followsWindowActiveState
        backdrop.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(backdrop)
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: content.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -28),
        ])
        panel.contentView = content
        return panel
    }
}

@MainActor
private final class LinkHandler: NSObject {
    static let shared = LinkHandler()

    @objc func openRepo() {
        if let url = URL(string: "https://github.com/robzilla1738/harness-terminal") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func copyCLIPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CLIInstaller.installedCLIPath.path, forType: .string)
    }
}
