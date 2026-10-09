// Generated from the CHANGELOG.md [2.0.2] block by Scripts/generate-release-notes.swift.
// DO NOT EDIT BY HAND — regenerate in release prep after updating CHANGELOG.md:
//   swift Scripts/generate-release-notes.swift
// Drift guards: ReleaseNotesGuardTests (version + changelog digest), package-app.sh.

extension ReleaseNotes {
    public static let current = ReleaseNotes(
        version: "2.0.2",
        changelogDigest: "99f9a1bc5d20c9fb",
        sections: [
            Section(title: "Fixed", items: [
                "Dock agent badges resize to fit inside the app icon, including when four agents are shown",
                "The terminal scrollbar hides after scrolling stops, including when macOS uses the legacy scrollbar style",
                "Notification setup no longer traps users behind an unanswered macOS permission request",
            ]),
            Section(title: "Changed", items: [
                "Harness Graphite is now the default theme and appears first in the collection",
            ]),
        ]
    )
}
