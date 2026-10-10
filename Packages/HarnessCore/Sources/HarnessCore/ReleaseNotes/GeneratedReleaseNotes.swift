// Generated from the CHANGELOG.md [2.2.0] block by Scripts/generate-release-notes.swift.
// DO NOT EDIT BY HAND — regenerate in release prep after updating CHANGELOG.md:
//   swift Scripts/generate-release-notes.swift
// Drift guards: ReleaseNotesGuardTests (version + changelog digest), package-app.sh.

extension ReleaseNotes {
    public static let current = ReleaseNotes(
        version: "2.2.0",
        changelogDigest: "b015f23971d841d4",
        sections: [
            Section(title: "Added", items: [
                "Stable session-host ownership of shells and PTYs, with compatible daemon handover, bounded replay, recovery, and explicit session-preserving update controls",
                "Durable agent execution history, tool timelines, usage accounting, deterministic digests, repository reports, and the Overview Board across attached hosts",
                "Encrypted macOS history with shared Keychain access, interruption-safe migration, unavailable-key recovery, retention controls, and capture opt-out",
                "Opt-in notification destinations, quiet hours, mute/snooze, speech, and daemon-owned power management with AC/battery policy",
                "Exact supported-provider resume, recorded command output, and Explain insertion without automatic submission",
                "Official Swift MCP integration with explicit tool permissions, cancellation, pane resources, and trusted local Lua plugins",
                "Managed worktrees and fan-out with pinned bases, actual workload outcomes, comparisons, cancellation, and protected cleanup",
                "Typed preview panes, managed remote forwards, reconnect recovery, and private remote image paste",
                "Reviewed recordings and asciicast export, tmux layout previews, Ghostty shortcut import, iTerm2 color import, process-tree resources, bounded regex search, schedules, and declarative hook policy",
                "Optional AI summaries with reviewed content consent, native provider adapters, current model discovery, cancellation, and deterministic-digest fallback",
                "Reproducible Linux packaging and atomic installer, rollback, signing, and uninstall engineering",
                "Recognition and sourced logos for 37 coding tools, including Devin, Abacus AI, MiniMax Code, and Trae",
            ]),
            Section(title: "Changed", items: [
                "First-run appearance uses Harness Graphite, 85% opacity, 60 pt blur, 25% border opacity, 8 pt tab gaps, and a hidden bottom status strip",
                "Coding-tool logos use uniform monochrome templates on transparent backgrounds",
                "Main Settings provides access to development tools, with consistent native controls and accessible labels",
                "Tab peek is a compact side panel with smoother presentation and terminal-style content",
                "API metadata declares capabilities, effects, and exposure surfaces; response negotiation preserves older-client compatibility",
            ]),
            Section(title: "Fixed", items: [
                "Build differences, failed health probes, and development conveniences no longer authorize terminating live sessions",
                "Terminal size synchronization releases stale client votes and orders attachment sizing so coding TUIs receive the available grid size",
                "Recovery, notification cancellation, Board selection, provider catalog storage, remote callbacks, and recording-share state follow their current operation identities",
                "Linux process inspection uses bounded native buffers, and unavailable disk history retains live activity in memory",
            ]),
        ]
    )
}
