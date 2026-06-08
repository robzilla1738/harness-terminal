// swift-format-ignore-file
// Generated from the CHANGELOG.md [1.8.0] block by Scripts/generate-release-notes.swift.
// DO NOT EDIT BY HAND — regenerate in release prep after updating CHANGELOG.md:
//   swift Scripts/generate-release-notes.swift
// Drift guards: ReleaseNotesGuardTests (version + changelog digest), package-app.sh.

extension ReleaseNotes {
    public static let current = ReleaseNotes(
        version: "1.8.0",
        changelogDigest: "72bf72aed313ab9f",
        sections: [
            Section(title: "Added", items: [
                "First-run welcome tour and post-update \"what's new\" banner",
                "~25 new #{…} format variables",
                "Full -t target grammar for select-pane / swap-pane",
                "Bindable config/buffer/hook verbs",
                "find-window",
                "Session/window lifecycle hook events",
                "Grouped sessions",
                "Server-admin verbs",
                "docs/TMUX_PARITY.md",
            ]),
            Section(title: "Fixed", items: [
                "synchronize-panes is one state across the GUI, the SSH compositor, and setw — toggles write the per-tab option through, so a snapshot push can't revert a local toggle",
                "GUI, compositor, and control mode surface daemon validation errors (unknown hook event, bad option scope) instead of reading as success; control mode emits %error for them",
                "CLI setw writes the tab scope like every other front-end (it silently wrote a global); scoped CLI sets resolve the calling pane via $HARNESS_SURFACE",
                "Option/env/buffer values that begin with - are no longer swallowed as flags (getopt-style parsing with -- support); a bare set-environment KEY errors instead of persisting \"\"",
                "Detaching attach-window restores the outer terminal title (set-titles); destroying the attached session re-pins the surviving session's workspace",
            ]),
        ]
    )
}
