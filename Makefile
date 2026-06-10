.PHONY: build bench bench-record bench-check preview preview-stop preview-clean release release-notes package dmg smoke-dmg sign appcast finalize hotfix-release icon clean

build:
	swift build

bench:
	HARNESS_BENCHMARKS=1 swift test -c release --filter HarnessBenchmarks

# Record the current run as the committed benchmark baseline (do this deliberately, in the
# same PR as an intentional performance change, on the hardware class you gate on).
bench-record:
	HARNESS_BENCHMARKS=1 swift test -c release --filter HarnessBenchmarks 2>&1 \
		| python3 Scripts/benchmarks/compare_benchmarks.py --record benchmark-baselines.json

# Compare a fresh run against the committed baseline; exits non-zero on a >15% regression.
bench-check:
	HARNESS_BENCHMARKS=1 swift test -c release --filter HarnessBenchmarks 2>&1 \
		| python3 Scripts/benchmarks/compare_benchmarks.py --baseline benchmark-baselines.json

preview:
	./Scripts/preview.sh

# preview-stop prefers a PID file (.harness-preview/.preview-pids, one PID per line) when
# present, falling back to a pkill pattern that deliberately does NOT embed $(CURDIR):
# the old '$(CURDIR)/...' pattern broke on repo paths containing spaces (the shell split
# it into multiple pkill arguments). The bundle-relative pattern matches only the preview
# app's binaries regardless of where the repo lives. preview.sh launches via `open` (no
# child PID to record), so today the fallback is the normal path; anything that starts
# the preview binaries directly can write the PID file to get precise targeting.
preview-stop:
	@if [ -f .harness-preview/.preview-pids ]; then \
		while IFS= read -r pid; do \
			[ -n "$$pid" ] && kill "$$pid" 2>/dev/null || true; \
		done < .harness-preview/.preview-pids; \
		rm -f .harness-preview/.preview-pids; \
	else \
		pkill -f 'HarnessPreview.app/Contents/MacOS/Harness' 2>/dev/null || true; \
		pkill -f 'HarnessPreview.app/Contents/MacOS/HarnessDaemon' 2>/dev/null || true; \
	fi

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
