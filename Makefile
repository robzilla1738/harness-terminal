.PHONY: build bench fmt fmt-check preview preview-stop preview-clean release release-notes package dmg smoke-dmg sign appcast finalize hotfix-release icon clean video-skills video-dev video-check video-render video-doctor

build:
	swift build

# Apply / check the shared swift-format style (config in .swift-format). Advisory: CI
# surfaces drift but never blocks a merge on it. Generated files opt out via a
# `// swift-format-ignore-file` header. `fmt` rewrites in place; `fmt-check` only lints.
FMT_PATHS := Apps Packages Tools Tests Package.swift

fmt:
	swift format --in-place --recursive --parallel $(FMT_PATHS)

fmt-check:
	swift format lint --recursive --parallel $(FMT_PATHS)

bench:
	HARNESS_BENCHMARKS=1 swift test -c release --filter HarnessBenchmarks

preview:
	./Scripts/preview.sh

preview-stop:
	-pkill -f '$(CURDIR)/.harness-preview/HarnessPreview.app/Contents/MacOS/Harness' 2>/dev/null
	-pkill -f '$(CURDIR)/.harness-preview/HarnessPreview.app/Contents/MacOS/HarnessDaemon' 2>/dev/null

preview-clean:
	rm -rf .harness-preview

icon:
	./Scripts/generate-app-icon.sh

# Regenerate the post-update banner's notes from the top CHANGELOG.md block.
# Run in release prep after editing CHANGELOG.md (guarded by ReleaseNotesGuardTests).
release-notes:
	swift Scripts/generate-release-notes.swift

release: icon
	./Scripts/build-release.sh

package: release

# Release order: make release -> make sign -> make dmg -> make finalize.
# dmg/sign/finalize operate on the EXISTING Harness.app so a prior signature is never
# rebuilt away. (When dmg/sign depended on `release`, running `make dmg` after `make sign`
# re-created an UNSIGNED Harness.app and shipped an unsigned DMG.) Each script fails clearly
# if Harness.app is missing, so run `make release` first.
dmg:
	./Scripts/create-dmg.sh

smoke-dmg:
	./Scripts/smoke-dmg.sh

sign:
	./Scripts/sign-and-notarize.sh

# Generate/refresh the Sparkle appcast from signed archives in ./dist (see the script header).
appcast:
	./Scripts/generate-appcast.sh

# Finalize a release: notarize + staple the DMG, re-upload to the GitHub release, build the
# appcast, optionally deploy it to the site. Needs ASC_ISSUER_ID (or APPLE_ID/APPLE_TEAM_ID/
# APPLE_APP_PASSWORD) and one keychain Allow for the Sparkle key. See Scripts/finalize-release.sh.
finalize:
	./Scripts/finalize-release.sh

hotfix-release:
	./Scripts/release-hotfix.sh

clean:
	swift package clean
	rm -rf Harness.app Harness.dmg Harness-notarize.zip dist .dmg-staging .icon-staging.iconset

# HyperFrames marketing video (marketing/video — see marketing/README.md)
video-skills:
	cd marketing/video && npx skills add heygen-com/hyperframes -y

video-dev:
	cd marketing/video && npm run dev

video-check:
	cd marketing/video && npm run check

video-render:
	cd marketing/video && npm run render

video-doctor:
	cd marketing/video && npx hyperframes doctor
