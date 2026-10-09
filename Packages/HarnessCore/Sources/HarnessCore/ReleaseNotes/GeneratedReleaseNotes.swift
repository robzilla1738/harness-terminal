// Generated from the CHANGELOG.md [2.0.1] block by Scripts/generate-release-notes.swift.
// DO NOT EDIT BY HAND — regenerate in release prep after updating CHANGELOG.md:
//   swift Scripts/generate-release-notes.swift
// Drift guards: ReleaseNotesGuardTests (version + changelog digest), package-app.sh.

extension ReleaseNotes {
    public static let current = ReleaseNotes(
        version: "2.0.1",
        changelogDigest: "e71b1298896a5220",
        sections: [
            Section(title: "Added", items: [
                "A curated collection of 25 original Harness themes: 17 dark and eight light palettes, with complete 16-color terminal palettes, coordinated cursors, and readable selections",
            ]),
            Section(title: "Changed", items: [
                "The original Harness collection appears first in theme pickers and command-palette suggestions",
                "Custom theme creation, editing, and .harnesstheme import/export remain available; current theme selections are preserved when updating",
            ]),
            Section(title: "Fixed", items: [
                "Theme-picker search receives keyboard focus instead of sending typed text to the Settings search field, and theme rows expose named accessibility actions",
            ]),
        ]
    )
}
