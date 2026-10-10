import AppKit
import HarnessCore

@MainActor
enum HookInstallationReview {
    static func approve(_ proposal: AgentHookInstaller.ProposedInstallation) -> Bool {
        let alert = NSAlert(); alert.messageText = "Review \(proposal.agent.displayName) hook configuration"
        alert.informativeText = proposal.needsManualMerge
            ? "The existing configuration cannot be edited safely. Use these additions for a manual merge; no files will be changed."
            : "Unrelated settings are retained and changed files receive private backups. Vendor trust approvals remain under your control. For Codex, review changed hooks through /hooks."
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 280))
        text.string = proposal.diff; text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let scroll = NSScrollView(frame: text.frame); scroll.hasVerticalScroller = true; scroll.documentView = text
        alert.accessoryView = scroll
        alert.addButton(withTitle: proposal.needsManualMerge ? "Close" : "Install")
        if !proposal.needsManualMerge { alert.addButton(withTitle: "Cancel") }
        return alert.runModal() == .alertFirstButtonReturn && !proposal.needsManualMerge
    }
}
