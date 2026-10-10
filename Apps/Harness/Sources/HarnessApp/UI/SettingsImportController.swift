import AppKit
import HarnessCore

@MainActor
enum SettingsImportController {
    static func present() {
        guard let imported = TerminalConfigImporter.load() else { DisplayMessage.show("No supported terminal configuration was found."); return }
        do {
            let expected = try PrivateFile.read(HarnessPaths.settingsURL)
            let patch = try SettingsImport(current: SessionCoordinator.shared.settings, imported: imported)
            let alert = NSAlert()
            alert.messageText = "Import \(imported.sourceName ?? "Terminal") Settings"
            alert.informativeText = "Choose what to bring into Harness. Changes to customized values start unchecked. Font size stays unchanged.\n\nSkipped settings: \(imported.skippedKeys.isEmpty ? "None" : imported.skippedKeys.joined(separator: ", "))"
            alert.addButton(withTitle: "Import Selected")
            alert.addButton(withTitle: "Cancel")
            let rows = NSStackView()
            rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
            var choices: [(String, HarnessToggle)] = []
            for change in patch.changes where change.key != "importedConfigSignature" {
                let choice = HarnessToggle(title: change.title + (change.replacesCustomization ? " · Customized" : ""))
                choice.state = change.replacesCustomization ? .off : .on
                choices.append((change.key, choice))
                rows.addArrangedSubview(choice)
                let summary: String
                if change.key == "paletteShortcuts", let data = change.after {
                    let shortcuts = try JSONDecoder().decode([String: String].self, from: data)
                    summary = shortcuts.sorted { $0.key < $1.key }.map { action, chord in
                        let title = CommandPaletteController.title(ofAction: action) ?? action
                        let conflict = ParsedShortcut.parse(chord).flatMap { PaletteShortcuts.shared.conflict(for: $0, excluding: action) }
                        return "\(title): \(chord)\(conflict.map { " · Also used by " + $0 } ?? "")"
                    }.joined(separator: "\n")
                } else { summary = change.summary }
                let detail = NSTextField(wrappingLabelWithString: summary)
                detail.textColor = .secondaryLabelColor
                detail.font = .systemFont(ofSize: 11)
                detail.widthAnchor.constraint(equalToConstant: 490).isActive = true
                rows.addArrangedSubview(detail)
            }
            if choices.isEmpty { DisplayMessage.show("The supported settings already match."); return }
            rows.translatesAutoresizingMaskIntoConstraints = false
            let reviewHeight = min(320, max(44, rows.fittingSize.height))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 510, height: reviewHeight))
            let document = FlippedStackHost()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(rows)
            scroll.hasVerticalScroller = true; scroll.documentView = document
            NSLayoutConstraint.activate([
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                rows.topAnchor.constraint(equalTo: document.topAnchor),
                rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                rows.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -16),
                rows.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            ])
            alert.accessoryView = scroll
            guard HarnessToolPage.runModal(alert) == .alertFirstButtonReturn else { return }
            let selected = Set(choices.filter { $0.1.state == .on }.map(\.0))
            guard !selected.isEmpty else { return }
            try patch.saveBackup(selected: selected)
            _ = try patch.applyFile(at: HarnessPaths.settingsURL, expected: expected, selected: selected)
            let settings = try HarnessSettings.reload()
            try SessionCoordinator.shared.applyImportedSettings(settings, persist: false)
            DisplayMessage.show("Imported \(selected.count) settings. Undo Last Settings Import is available in the menu and palette.")
        } catch { DisplayMessage.show("Import failed: \(error.localizedDescription)") }
    }

    static func undo() {
        do {
            guard let data = try PrivateFile.read(SettingsImport.backupURL) else { throw SetupError.invalid("No settings import backup is available.") }
            let patch = try JSONDecoder().decode(SettingsImport.self, from: data)
            let settings = try patch.undo(in: SessionCoordinator.shared.settings)
            try SessionCoordinator.shared.applyImportedSettings(settings)
            try FileManager.default.removeItem(at: SettingsImport.backupURL)
            DisplayMessage.show("Reverted imported values that have not been edited since.")
        } catch { DisplayMessage.show("Could not undo the import: \(error.localizedDescription)") }
    }
}
