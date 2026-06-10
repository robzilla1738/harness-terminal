// Generated from the CHANGELOG.md [1.9.0] block by Scripts/generate-release-notes.swift.
// DO NOT EDIT BY HAND — regenerate in release prep after updating CHANGELOG.md:
//   swift Scripts/generate-release-notes.swift
// Drift guards: ReleaseNotesGuardTests (version + changelog digest), package-app.sh.

extension ReleaseNotes {
    public static let current = ReleaseNotes(
        version: "1.9.0",
        changelogDigest: "ce68ecd240073370",
        sections: [
            Section(title: "Added", items: [
                "Quick terminal: a Quake-style global-hotkey dropdown",
                "Find bar: regular-expression and case-sensitivity toggles",
                "Unlimited scrollback",
                "Four Ghostty-style quality-of-life features",
                "Terminal bell feedback (audible / visual)",
                "clear-history — clear a pane's scrollback without respawning the shell",
                "status-interval is now honored",
                "Bindable send-keys -l/-H, display-message -p, and four more hooks",
                "Copy-mode jump-to-char and friends",
                "More format operators",
                "Kitty graphics protocol: ack, query, transmit-once/place-many, delete",
                "status-position is now honored",
                "@-prefixed user options",
                "VoiceOver support for the terminal grid",
                "Secure Keyboard Entry",
            ]),
            Section(title: "Changed", items: [
                "Agent scanning builds the process tree once per tick",
                "One key-encoder",
                "Layout persistence moved off the input-latency path",
            ]),
            Section(title: "Fixed", items: [
                "The window-edge border now hugs the rounded corners",
                "The agent notch opens and closes as one motion",
                "The notch no longer shows one agent as both waiting and working",
                "The agent-update peek clears the notch",
                "Clicking a notch row restores a minimized window",
                "capture-pane (plain mode) now strips DCS / charset-designation escapes",
                "VT correctness cluster (REP / IRM / DECOM / DECSTR / DECALN)",
                "DCS device-control strings are now demuxed instead of all being fed to the Sixel decoder",
                "Primary device attributes (DA1) now advertise Sixel",
                "Three copy-mode motions were silently mis-aliased to the wrong action",
                "set-option now rejects unknown option names loudly",
                "Format conditionals can now nest an operator in the test",
            ]),
            Section(title: "Security", items: [
                "Paste-injection hardening",
                "OSC 7 working-directory validation",
            ]),
        ]
    )
}
