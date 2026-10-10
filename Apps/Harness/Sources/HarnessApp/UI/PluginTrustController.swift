import AppKit
import HarnessCore

@MainActor
enum PluginTrustController {
    static func review(relativeTo parent: NSWindow?) {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.allowsMultipleSelection = false
        picker.message = "Choose a local plugin.json manifest to review its declared actions and Lua entry code. No plugin code runs during review."
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let proposed = try TrustedPlugins.prepare(url)
            let current = try TrustedPlugins.load().first { $0.id == proposed.id }
            let alert = NSAlert(); alert.messageText = current == nil ? "Trust this local Lua plugin?" : "Replace the approved plugin code?"
            alert.informativeText = "Lua has your user privileges, including files and processes. Review every entry below. External modules and programs invoked by these entries also require your trust. Harness stores the approved entries; edits to the original files require another review."
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 380)); text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = proposed.review
            if let current { text.string += "\n\nPREVIOUS APPROVED ENTRIES\n\n" + current.review }
            text.setAccessibilityLabel("Proposed plugin entry code and previously approved entries")
            let scroll = NSScrollView(frame: text.frame); scroll.hasVerticalScroller = true; scroll.documentView = text
            alert.accessoryView = scroll; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Trust reviewed entries")
            guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
            try TrustedPlugins.approve(proposed)
            let success = NSAlert(); success.messageText = "Plugin approved"
            success.informativeText = "Reopen the palette to invoke its declared actions. The plugin is " + proposed.manifest.title + "."
            HarnessToolPage.runModal(success)
        } catch { show(error) }
    }
    static func revoke(_ id: String) {
        let alert = NSAlert(); alert.messageText = "Revoke plugin trust?"
        alert.informativeText = "Actions from " + id + " will be removed from the palette. Existing invocations finish independently."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Revoke trust")
        guard HarnessToolPage.runModal(alert) == .alertSecondButtonReturn else { return }
        do { try TrustedPlugins.revoke(id) } catch { show(error) }
    }
    private static func show(_ error: Error) { let alert = NSAlert(); alert.messageText = "Plugin configuration could not be completed"; alert.informativeText = error.localizedDescription; HarnessToolPage.runModal(alert) }
}
