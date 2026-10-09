# Harness architecture and provenance

This document describes the current implementation, its recorded development
history and retained third-party material. It distinguishes runtime dependencies,
interoperability and historical comparisons. It does not claim that every algorithm
or technique originated in this project.

## Current implementation

| Component | Implementation in this repository |
| --- | --- |
| Terminal parser, screen and history | `Packages/HarnessTerminalEngine` |
| Core settings, IPC models and commands | `Packages/HarnessCore` |
| Persistent PTYs and session ownership | `Packages/HarnessDaemonCore` and daemon executable |
| Native terminal surface and input | `Packages/HarnessTerminalKit` |
| Glyph atlas, damage-driven frames and Metal rendering | `Packages/HarnessTerminalRenderer` |
| Theme parsing and catalog | `Packages/HarnessTheme` |
| macOS application | `Apps/Harness` |
| Mobile companion protocol | Curated portable sources shared with [harness-ios](https://github.com/robzilla1738/harness-ios) |

The current `Package.swift`, resolved package graph and app project do not link
libghostty. Sparkle is the external Swift package used by the macOS app for updates.
The CLI links vendored Lua 5.1; image decoding uses vendored stb_image. Fonts, agent
marks and community themes also carry their own licenses. The root MIT license
covers Harness's own work; it does not replace third-party licenses.

## Recorded development history

Early Harness builds used a libghostty wrapper. Native parser/screen and renderer
packages were introduced during subsequent development. Commit
[`1943f5c`](https://github.com/robzilla1738/harness-terminal/commit/1943f5c)
removed the libghostty package dependency, app wiring and dependency-based oracle
tests. Earlier release tags and commits retain the implementation they shipped.

Removing that dependency establishes the current build architecture. It does not,
by itself, establish the origin of every surviving line. This review checked the
current dependency declarations, the recorded replacement commit, third-party
notices, compatibility references and packaging. It was not an exhaustive comparison
of every historical source file against every upstream revision.

## Compatibility references

These names identify external formats or actual behavior, rather than implementation
dependencies or affiliation:

- **Config import:** the importer recognizes Ghostty configuration paths, keys and
  theme files. The UI identifies the source being imported. Removing those paths or
  labels would break migration or make the review less clear.
- **Terminal identity:** the default `compatible` mode reports `ghostty` in
  `TERM_PROGRAM` and XTVERSION replies for tools that detect keyboard support by
  terminal name. Harness still uses its own packages. Use `harness-cli set-option terminal-identity harness` to report the product name;
  name-based tool detection may differ.
- **Legacy theme names:** saved names such as `Ghostty Default` resolve through
  compatibility aliases. They are not the name of the current default theme.
- **Program status:** OSC 7501 revision 0.2 follows the public
  [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status).
  Harness's parser and presentation implement this interoperable format. Protocol
  attribution is retained; it does not imply a Rex runtime dependency.
- **Shell startup:** bash integration uses the `--posix`/`ENV` injection technique
  also used by kitty and Ghostty. The source comment retains that recorded lineage.
- **Measurements:** benchmark scripts and historical results name the reference
  application actually measured. Relabeling those results would lose evidence.

## Retained material and notices

Community palette data was exported through Ghostty's theme catalog from the
[iTerm2-Color-Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes) collection.
That origin and the applicable collection license remain in
[third-party notices](THIRD-PARTY-NOTICES.md). Original Harness palettes coexist
with these community palettes; the two should not be represented as having the
same origin.

`Scripts/package-app.sh` includes the third-party notices in the app bundle.
Agent artwork has a separate source/hash/license catalog and packaged license
texts. Vendored code and fonts retain their applicable notices. Review the
third-party inventory whenever adding, replacing or removing bundled material.

## Public documentation policy

Describe features and constraints directly. Use external names where needed for
compatibility, attribution or reproducible measurements. Avoid comparison-based
implementation explanations and unsupported claims of originality or superiority.

Historical changelogs, benchmark evidence, commits, releases and closed discussions
remain records of what happened. Current architecture and capabilities are maintained
here and in [Capabilities and limits](CAPABILITIES.md). Cleanup does not rewrite
published history or remove required notices.
