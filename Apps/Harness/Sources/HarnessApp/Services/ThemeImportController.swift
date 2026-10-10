import AppKit
import HarnessCore
import HarnessTheme

/// How an externally-opened URL should be handled. Pure classification so the routing
/// decision in `AppDelegate.enqueueExternalOpen` is unit-testable without AppKit state.
enum ExternalOpenKind: Equatable {
    /// A `.harnesstheme` document — import + install + offer to apply.
    case theme
    /// Everything else (folders, ssh/telnet/man URLs, `.command`/`.tool`/scripts/executables)
    /// routes through `DefaultTerminalOpener` exactly as before.
    case terminal

    /// Classify by file extension only. A theme file is a regular `.harnesstheme` file; any
    /// other URL (including non-file URL schemes like `ssh://`) is a terminal open.
    init(for url: URL) {
        if url.isFileURL,
           url.pathExtension.lowercased() == ThemeDocument.fileExtension {
            self = .theme
        } else {
            self = .terminal
        }
    }
}

/// Imports `.harnesstheme` files opened from the Finder (double-click / "Open With Harness").
/// Reads + validates the document, installs it into the user's themes folder for re-sharing,
/// then offers to apply it. Parse failures surface as a loud alert instead of silently doing
/// nothing — the old behavior routed theme files through the shell-script opener.
@MainActor
enum ThemeImportController {
    private static let fileService = ThemeFileService()

    /// Handle one opened theme file end-to-end.
    static func handle(_ url: URL) {
        let document: ThemeDocument
        do {
            document = try fileService.importTheme(from: url)
        } catch {
            presentFailure(url: url, error: error)
            return
        }

        finish(document, source: url)
    }

    static func presentITermImport() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an iTerm2 .itermcolors preset to preview. No settings change until you choose Install and Apply."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "Select color variant"; alert.informativeText = "Dark/light values fall back to base colors when a variant is absent."
        let variants = HarnessSelect(); variants.frame = NSRect(x: 0, y: 0, width: 280, height: HarnessDesign.formControlHeight); variants.setAccessibilityLabel("Color variant"); variants.addItems(withTitles: ["Base", "Dark", "Light"])
        alert.accessoryView = variants; alert.addButton(withTitle: "Preview"); alert.addButton(withTitle: "Cancel")
        guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
        do {
            guard let data = try PrivateFile.read(url) else { throw ThemeDocumentError.malformed("Color file is unavailable") }
            let variant: ITermColorImport.Variant = [.base, .dark, .light][variants.indexOfSelectedItem]
            let proposal = try ITermColorImport.parse(data, name: url.deletingPathExtension().lastPathComponent, variant: variant)
            finish(proposal.document, source: url, warnings: proposal.warnings)
        } catch { presentFailure(url: url, error: error) }
    }

    private static func finish(_ document: ThemeDocument, source: URL, warnings: [String] = []) {
        let choice = presentInstallChoice(for: document, warnings: warnings)
        guard choice != .cancel else { return }
        do {
            _ = try fileService.install(document, into: HarnessPaths.themesDirectory)
            ThemeLibrary.reload()
            if choice == .installAndApply { try SessionCoordinator.shared.applyImportedTheme(document) }
        } catch { presentFailure(url: source, error: error) }
    }

    private enum InstallChoice {
        case install
        case installAndApply
        case cancel
    }

    private static func presentInstallChoice(for document: ThemeDocument, warnings: [String]) -> InstallChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Install theme “\(document.name)”?"
        var info = "Add this theme to Harness."
        if let author = document.author, !author.isEmpty {
            info += " By \(author)."
        }
        info += "\nExisting theme and settings files receive private backups.\n" + warnings.joined(separator: "\n")
        alert.informativeText = info
        let rows = NSStackView(); rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        let sample = NSTextField(labelWithString: "Aa 0123456789 · foreground on background")
        func color(_ value: HarnessTheme.RGBColor) -> NSColor { NSColor(srgbRed: CGFloat(value.red) / 255, green: CGFloat(value.green) / 255, blue: CGFloat(value.blue) / 255, alpha: 1) }
        sample.drawsBackground = true; sample.backgroundColor = color(document.colors.background); sample.textColor = color(document.colors.foreground); sample.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        sample.setAccessibilityLabel("Foreground " + document.colors.foreground.hexString + " on background " + document.colors.background.hexString)
        rows.addArrangedSubview(sample)
        for start in [0, 8] {
            let row = NSStackView(); row.spacing = 4
            for index in start..<(start + 8) {
                let value = document.colors.palette[index], label = NSTextField(labelWithString: String(index)); label.drawsBackground = true; label.backgroundColor = color(value); label.textColor = (0.2126 * Double(value.red) + 0.7152 * Double(value.green) + 0.0722 * Double(value.blue)) > 145 ? .black : .white; label.widthAnchor.constraint(equalToConstant: 38).isActive = true
                label.setAccessibilityLabel("ANSI \(index): " + value.hexString); row.addArrangedSubview(label)
            }; rows.addArrangedSubview(row)
        }
        alert.accessoryView = rows
        // First button is the default (return-key) action; order them install / apply / cancel.
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Install and Apply")
        alert.addButton(withTitle: "Cancel")
        switch HarnessToolPage.runModal(alert) {
        case .alertFirstButtonReturn: return .install
        case .alertSecondButtonReturn: return .installAndApply
        default: return .cancel
        }
    }

    private static func presentFailure(url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Couldn’t open theme “\(url.lastPathComponent)”"
        alert.informativeText = describe(error)
        alert.addButton(withTitle: "OK")
        HarnessToolPage.runModal(alert)
    }

    /// Human-readable text for the theme parse/validation errors so the alert is actionable.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? ThemeDocumentError else {
            return (error as NSError).localizedDescription
        }
        switch error {
        case let .unsupportedVersion(version):
            return "This theme uses format version \(version), which this version of Harness can’t read. Update Harness and try again."
        case .emptyName:
            return "The theme file is missing a name."
        case let .wrongPaletteCount(count):
            return "The theme has \(count) ANSI colors but exactly 16 are required."
        case let .malformed(detail):
            return "The theme file isn’t valid: \(detail)"
        }
    }
}
