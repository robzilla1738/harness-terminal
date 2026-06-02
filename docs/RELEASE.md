# Release runbook

Harness can be released from GitHub Actions on a hosted macOS runner. The
`Release Harness` workflow builds the app, signs it with Developer ID, notarizes
the app and DMG, uploads the DMG to GitHub Releases, generates a Sparkle appcast,
and can optionally commit that appcast to the website repository.

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

1. Merge the code and version bump that should ship.
2. Open **Actions -> Release Harness -> Run workflow**.
3. Select the release branch, normally `main`.
4. Enter a tag matching `CFBundleShortVersionString`, for example `v1.0.4`.
5. Enable `deploy_appcast` only after `WEBSITE_REPOSITORY` and
   `WEBSITE_DEPLOY_TOKEN` are configured.
6. Approve the `release` environment gate when GitHub asks.

The workflow validates that the tag version matches `Info.plist` before signing
anything. If the version still says `1.0.3`, a `v1.0.4` run fails fast and tells
you to bump `CFBundleShortVersionString` / `CFBundleVersion` first.

## What the workflow publishes

- A GitHub Release for the requested tag, created at the workflow commit if one
  does not already exist.
- `Harness.dmg`, uploaded or replaced on that GitHub Release.
- `dist/appcast.xml`, uploaded to the GitHub Release for audit/debugging.
- Optionally, `public/appcast.xml` in the website repository.

Installed apps only see the update after `https://harnesscli.dev/appcast.xml`
serves the new appcast. If `deploy_appcast` is disabled, manually publish
`dist/appcast.xml` to the website before expecting Sparkle auto-update to find
the release.

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

Without `SPARKLE_EDDSA_PRIVATE_KEY_FILE`, Sparkle falls back to the private key in
the login keychain and may show an interactive "Allow" prompt.
