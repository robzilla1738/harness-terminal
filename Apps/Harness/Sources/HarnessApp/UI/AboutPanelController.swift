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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "About Harness"
        panel.isFloatingPanel = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let icon = NSApp.applicationIconImage {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: 64).isActive = true
            iconView.heightAnchor.constraint(equalToConstant: 64).isActive = true
            stack.addArrangedSubview(iconView)
        }

        let title = NSTextField(labelWithString: "Harness")
        title.font = .boldSystemFont(ofSize: 20)
        stack.addArrangedSubview(title)

        let tagline = NSTextField(wrappingLabelWithString: "Native macOS terminal for AI agents and dev sessions.\nGPU rendering via libghostty.")
        tagline.alignment = .center
        tagline.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(tagline)

        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(versionLabel)

        let cliLabel = NSTextField(wrappingLabelWithString: "harness-cli:\n\(cliPath)")
        cliLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        cliLabel.alignment = .center
        cliLabel.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(cliLabel)

        let link = NSButton(title: "github.com/robert/harness", target: nil, action: nil)
        link.bezelStyle = .inline
        link.isBordered = false
        link.contentTintColor = .linkColor
        link.target = LinkHandler.shared
        link.action = #selector(LinkHandler.openRepo)
        stack.addArrangedSubview(link)

        let copyCLI = NSButton(title: "Copy harness-cli path", target: nil, action: nil)
        copyCLI.bezelStyle = .rounded
        copyCLI.target = LinkHandler.shared
        copyCLI.action = #selector(LinkHandler.copyCLIPath)
        stack.addArrangedSubview(copyCLI)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
        return panel
    }
}

@MainActor
private final class LinkHandler: NSObject {
    static let shared = LinkHandler()

    @objc func openRepo() {
        if let url = URL(string: "https://github.com/robert/harness") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func copyCLIPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(CLIInstaller.installedCLIPath.path, forType: .string)
    }
}
