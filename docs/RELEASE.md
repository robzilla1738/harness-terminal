# Release runbook

Harness can be released from GitHub Actions on a hosted macOS runner. The
`Release Harness` workflow ([`.github/workflows/release.yml`](../.github/workflows/release.yml))
builds the app, signs it with Developer ID, notarizes the app and DMG, uploads the
DMG to GitHub Releases, generates a Sparkle appcast, and can optionally commit that
appcast to the website repository.

It runs on the `macos-26` runner with Xcode 26.6, the same runner and pinned
`XCODE_VERSION` as CI, so a release is built by the toolchain CI tested. Bump
`XCODE_VERSION` in `release.yml` and `ci.yml` together.

## Harness 2.0 release preparation

The user authorized the 2.0.0 release on October 9, 2026. Build 129 includes the terminal,
workspace, and Mac usability changes from #185 and the reliability, Unicode, and color-glyph
follow-up in #188. Version declarations and generated update notes are updated together.

The [release-readiness review](RELEASE-READINESS-2026-10-09.md) records validation and
older-log replay limits. Hardware acceptance remains tracked in
[#187](https://github.com/robzilla1738/harness-terminal/issues/187); measured performance gaps
remain in [#27](https://github.com/robzilla1738/harness-terminal/issues/27) and the
[scorecard](SCORECARD.md). These remain scoped limitations of the release, rather than claims
of universal compatibility or performance leadership. CI must pass on the shipping commit,
and signing, notarization, DMG smoke testing, and live appcast verification must complete
before publication. The GitHub release and workflow run record the publication outcome.

## One-time GitHub setup

Create a protected GitHub Environment named `release` and add required reviewers
before storing release secrets there. That keeps the signing material unavailable
until a human approves a release run.

Required environment secrets:

| Secret | Purpose |
| --- | --- |
| `SIGNING_CERTIFICATE_BASE64` | Base64-encoded `.p12` export for the Developer ID Application certificate. |
| `SIGNING_CERTIFICATE_PASSWORD` | Password for the `.p12` export. |
| `SIGNING_IDENTITY` | Exact codesign identity, for example `Developer ID Application: Name (TEAMID)`. |
| `ASC_ISSUER_ID` | App Store Connect API issuer UUID. |
| `ASC_KEY_ID` | App Store Connect API key ID. |
| `ASC_PRIVATE_KEY` | Contents of the App Store Connect `AuthKey_<key-id>.p8` file. |
| `SPARKLE_EDDSA_PRIVATE_KEY` | Sparkle EdDSA private key matching `SUPublicEDKey` in `Info.plist`. |

Optional appcast deploy settings:

| Setting | Purpose |
| --- | --- |
| Environment variable `WEBSITE_REPOSITORY` | Website repository in `owner/name` form. The workflow writes `public/appcast.xml` there. |
| Secret `WEBSITE_DEPLOY_TOKEN` | Token with write access to `WEBSITE_REPOSITORY`. Use this only if `deploy_appcast` is enabled. |

The website deploy path assumes the website repository owns `harnesscli.dev` and
deploys after a push, for example through Vercel's Git integration. The DMG does
not need to be copied to the website: the generated appcast points Sparkle at
the GitHub Release asset URL for the matching tag.

## Running a release from GitHub

1. Merge the code and version bump that should ship, and check that CI is green
   on that commit (see [CI](#ci) below).
2. Open **Actions -> Release Harness -> Run workflow**.
3. Select the release branch, normally `main`.
4. Enter `tag` (required): `vX.Y.Z` matching `CFBundleShortVersionString`, for
   example `v1.0.4`.
5. Optionally enter `release_name`; it defaults to `Harness <version> (<build>)`.
6. Enable `deploy_appcast` (default off) only after `WEBSITE_REPOSITORY` and
   `WEBSITE_DEPLOY_TOKEN` are configured.
7. Approve the `release` environment gate when GitHub asks.

The workflow validates the tag before signing anything: it must look like
`vX.Y.Z`, its version must match `CFBundleShortVersionString` in
`Apps/Harness/Sources/HarnessApp/Resources/Info.plist`, and
`HarnessVersion.short` / `HarnessVersion.build` must match the plist's
`CFBundleShortVersionString` / `CFBundleVersion`. If the version still says
`1.0.3`, a `v1.0.4` run fails fast and tells you to bump them first. It then
checks that every required secret is set (and, with `deploy_appcast`, the website
settings). Only one release runs at a time; a second dispatch queues behind it.

Bump `HarnessVersion.swift` (`short` + `build` in `Packages/HarnessCore`) in the
same commit as `Info.plist` — the daemon and CLI report versions from those
constants, and `Scripts/package-app.sh` + the workflow fail the build when the
two disagree (v1.3.0/v1.3.1 shipped daemons that reported 1.2.0). Edit the plist
as plain text; `PlistBuddy Set` re-serializes the whole file. Also move the
`CHANGELOG.md` `[Unreleased]` section under the new version heading, then run
`make release-notes` to regenerate the post-update banner's notes from the top
`CHANGELOG.md` block (`ReleaseNotesGuardTests` fails when they are stale).

After dispatching, verify the run's `headSha` equals the release-prep commit
before approving the `release` environment (a push that failed on a network
blip once left `workflow_dispatch` running from the OLD head). Known flake:
`hdiutil` "Resource busy" during DMG creation — rerun failed jobs and re-approve
the environment.

## What the workflow does

In order: `make release` (build `Harness.app`), check the bundle has no stray
resource bundles, `make sign` (sign and notarize the app), `make dmg`, create a
**draft** GitHub Release for the tag if none exists, `make finalize` (notarize and
staple the DMG, upload it to the release, generate `dist/appcast.xml`),
`Scripts/smoke-dmg.sh Harness.dmg`, upload the appcast to the release, and, with
`deploy_appcast`, commit `public/appcast.xml` to the website repository and wait
(up to about five minutes) for `https://harnesscli.dev/appcast.xml` to serve it.
Only then is the release published and marked latest. `Harness.dmg` and
`dist/appcast.xml` are also kept as the run's `harness-release-<tag>` artifact,
and the temporary signing keychain is deleted even when a step fails.

## What the workflow publishes

- A GitHub Release for the requested tag, created as a draft at the workflow
  commit if one does not already exist, and published as the latest release once
  every step has passed.
- `Harness.dmg`, uploaded or replaced on that GitHub Release.
- `dist/appcast.xml`, uploaded to the GitHub Release for audit/debugging.
- Optionally, `public/appcast.xml` in the website repository.

Installed apps only see the update after `https://harnesscli.dev/appcast.xml`
serves the new appcast. If `deploy_appcast` is disabled, manually publish
`dist/appcast.xml` to the website before expecting Sparkle auto-update to find
the release.

## CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on pushes to
`main` and `claude/**` branches and on pull requests:

| Job | Runner | What it checks |
| --- | --- | --- |
| Build & test (macOS) | `macos-26`, Xcode 26.6 | `swift build`, `swift build -c release`, and `swift test --enable-code-coverage` with `HARNESS_LIVE_DAEMON_TESTS=1`; uploads the coverage data. |
| Build & test (Linux, headless daemon) | `ubuntu-24.04`, `swift:6.0` container | Debug and release builds of the daemon, CLI, and pure libraries, then `swift test` with the live daemon tests. |
| Xcode project builds | `macos-26`, Xcode 26.6 | `xcodebuild` Debug build of the committed `Harness.xcodeproj`, so drift between `project.yml` and the targets is caught. |
| Manifest version agreement | `ubuntu-24.04` | The Sparkle version agrees across `Package.swift`, `project.yml`, and `project.pbxproj`. |
| Format lint (advisory) | `macos-26` | `swift format lint`; never blocks. |
| Benchmarks (non-blocking) | `macos-26` | `swift test -c release --filter HarnessBenchmarks`; never blocks. |

Releases build with SwiftPM (`make release`), so the macOS build-and-test job is
the one a release depends on.

## Local release path

The local path still works:

```bash
make release
SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
ASC_ISSUER_ID=... ASC_KEY_ID=... ASC_KEY=/path/to/AuthKey.p8 \
  make sign
make dmg
TAG=vX.Y.Z \
ASC_ISSUER_ID=... ASC_KEY_ID=... ASC_KEY=/path/to/AuthKey.p8 \
SPARKLE_EDDSA_PRIVATE_KEY_FILE=/path/to/sparkle-private-key \
DOWNLOAD_URL_PREFIX="https://github.com/robzilla1738/harness-terminal/releases/download/vX.Y.Z/" \
  make finalize
```

`make finalize` uploads the DMG to an existing GitHub Release for `TAG`, so
create the release (for example as a draft) before running it. `DEPLOY_WEBSITE=1
WEBSITE_DIR=…` also copies the appcast into the website checkout and deploys it;
see the header of `Scripts/finalize-release.sh`.

Without `SPARKLE_EDDSA_PRIVATE_KEY_FILE`, Sparkle falls back to the private key in
the login keychain and may show an interactive "Allow" prompt.
