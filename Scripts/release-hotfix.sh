#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'USAGE'
Usage:
  Scripts/release-hotfix.sh --tag vX.Y.Z --build N [options]

Options:
  --version X.Y.Z       CFBundleShortVersionString. Defaults to the tag without "v".
  --release-name NAME   GitHub release title. Defaults to "Harness X.Y.Z (N)".
  --no-deploy-appcast   Do not commit appcast.xml to the website repository.
  --skip-tests          Skip swift test before dispatching the release workflow.
  --dry-run             Print the plan without changing files or dispatching GitHub Actions.
  -h, --help            Show this help.

What this does:
  1. Requires a clean tracked worktree.
  2. Updates Harness Info.plist to version/build.
  3. Runs swift test unless --skip-tests is set.
  4. Commits, pushes main, and force-moves the requested tag.
  5. Dispatches the Release Harness workflow and watches it.
  6. Validates the GitHub release appcast and the live website appcast.
  7. Downloads the final DMG, computes SHA-256, updates README download copy,
     commits/pushes it, force-moves the tag, and retargets the GitHub release.
USAGE
}

tag=""
version=""
build=""
release_name=""
deploy_appcast=1
run_tests=1
dry_run=0

while (($#)); do
  case "$1" in
    --tag)
      tag="${2:?Missing value for --tag}"
      shift 2
      ;;
    --version)
      version="${2:?Missing value for --version}"
      shift 2
      ;;
    --build)
      build="${2:?Missing value for --build}"
      shift 2
      ;;
    --release-name)
      release_name="${2:?Missing value for --release-name}"
      shift 2
      ;;
    --no-deploy-appcast)
      deploy_appcast=0
      shift
      ;;
    --skip-tests)
      run_tests=0
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$tag" ]] || { echo "Missing --tag vX.Y.Z" >&2; exit 2; }
[[ -n "$build" ]] || { echo "Missing --build N" >&2; exit 2; }
[[ "$tag" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]] || { echo "--tag must look like vX.Y.Z" >&2; exit 2; }
[[ "$build" =~ ^[0-9]+$ ]] || { echo "--build must be numeric" >&2; exit 2; }

if [[ -z "$version" ]]; then
  version="${tag#v}"
fi
[[ "$version" == "${tag#v}" ]] || { echo "--version must match --tag without v" >&2; exit 2; }

if [[ -z "$release_name" ]]; then
  release_name="Harness $version ($build)"
fi

deploy_appcast_input=false
if [[ "$deploy_appcast" == "1" ]]; then
  deploy_appcast_input=true
fi

run() {
  echo "+ $*"
  if [[ "$dry_run" == "0" ]]; then
    "$@"
  fi
}

require_clean_tracked_worktree() {
  local status
  status="$(git status --porcelain --untracked-files=no)"
  if [[ -n "$status" ]]; then
    echo "Tracked worktree changes exist. Commit/stash them before releasing:" >&2
    echo "$status" >&2
    exit 1
  fi
}

plist_set() {
  local key="$1"
  local value="$2"
  run /usr/libexec/PlistBuddy -c "Set :$key $value" Apps/Harness/Sources/HarnessApp/Resources/Info.plist
}

workflow_run_id_for_head() {
  local head_sha="$1"
  local id=""
  for _ in {1..30}; do
    id="$(gh run list \
      --workflow release.yml \
      --branch main \
      --event workflow_dispatch \
      --limit 10 \
      --json databaseId,headSha \
      --jq ".[] | select(.headSha == \"$head_sha\") | .databaseId" | head -1)"
    if [[ -n "$id" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
    sleep 2
  done
  return 1
}

update_readme_download() {
  local checksum="$1"
  local tmp
  tmp="$(mktemp)"

  awk -v tag="$tag" -v version="$version" -v build="$build" -v checksum="$checksum" '
    /^\*\*\[Download Harness / {
      print "**[Download Harness " version " (" build ") for macOS ->](https://github.com/robzilla1738/harness-terminal/releases/download/" tag "/Harness.dmg)**"
      next
    }
    /^SHA-256: `/ {
      print "SHA-256: `" checksum "`"
      next
    }
    { print }
  ' README.md > "$tmp"

  if [[ "$dry_run" == "0" ]]; then
    mv "$tmp" README.md
  else
    rm -f "$tmp"
  fi
}

write_release_notes() {
  local checksum="$1"
  local notes="$2"
  cat > "$notes" <<EOF
Signed and notarized Harness $version ($build).

- Version: $version
- Build: $build
- macOS: 15.0 or later
- Architecture: Apple silicon (arm64)
- SHA-256: $checksum
EOF
}

echo "Release plan:"
echo "  tag: $tag"
echo "  version: $version"
echo "  build: $build"
echo "  release name: $release_name"
echo "  deploy appcast: $deploy_appcast_input"
echo "  run tests: $run_tests"
echo

if [[ "$dry_run" == "0" ]]; then
  require_clean_tracked_worktree
else
  tracked_status="$(git status --porcelain --untracked-files=no)"
  if [[ -n "$tracked_status" ]]; then
    echo "Dry run: tracked worktree changes are present; a real release would stop here:"
    echo "$tracked_status"
  fi
fi

current_branch="$(git branch --show-current)"
if [[ "$current_branch" != "main" ]]; then
  run git switch main
fi

run git fetch origin main --tags
run git pull --ff-only origin main

plist_set CFBundleShortVersionString "$version"
plist_set CFBundleVersion "$build"

run git diff -- Apps/Harness/Sources/HarnessApp/Resources/Info.plist

if [[ "$run_tests" == "1" ]]; then
  run swift test
fi

if ! git diff --quiet -- Apps/Harness/Sources/HarnessApp/Resources/Info.plist; then
  run git add Apps/Harness/Sources/HarnessApp/Resources/Info.plist
  run git commit -m "Prepare Harness $version build $build release"
else
  echo "Info.plist already has the requested version/build."
fi

run git push origin main
run git tag -f "$tag" HEAD
run git push origin "refs/tags/$tag" --force

head_sha="$(git rev-parse HEAD)"
run gh workflow run release.yml \
  --repo robzilla1738/harness-terminal \
  -f "tag=$tag" \
  -f "release_name=$release_name" \
  -f "deploy_appcast=$deploy_appcast_input"

if [[ "$dry_run" == "1" ]]; then
  echo "Dry run complete."
  exit 0
fi

run_id="$(workflow_run_id_for_head "$head_sha")" || {
  echo "Could not find dispatched Release Harness workflow run for $head_sha" >&2
  exit 1
}

echo "Watching workflow run $run_id..."
gh run watch "$run_id" --repo robzilla1738/harness-terminal --exit-status

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

gh release download "$tag" \
  --repo robzilla1738/harness-terminal \
  --pattern appcast.xml \
  --dir "$tmpdir"

grep -q "<sparkle:version>$build</sparkle:version>" "$tmpdir/appcast.xml"
grep -q "<sparkle:shortVersionString>$version</sparkle:shortVersionString>" "$tmpdir/appcast.xml"
grep -q "https://github.com/robzilla1738/harness-terminal/releases/download/$tag/Harness.dmg" "$tmpdir/appcast.xml"
grep -q "sparkle:edSignature=" "$tmpdir/appcast.xml"

if [[ "$deploy_appcast" == "1" ]]; then
  curl -fsSL -H 'Cache-Control: no-cache' https://harnesscli.dev/appcast.xml -o "$tmpdir/live-appcast.xml"
  diff -u "$tmpdir/appcast.xml" "$tmpdir/live-appcast.xml"
fi

gh release download "$tag" \
  --repo robzilla1738/harness-terminal \
  --pattern Harness.dmg \
  --dir "$tmpdir"

checksum="$(shasum -a 256 "$tmpdir/Harness.dmg" | awk '{print $1}')"
update_readme_download "$checksum"

if ! git diff --quiet -- README.md; then
  run git add README.md
  run git commit -m "Update Harness $version build $build download copy"
  run git push origin main
  run git tag -f "$tag" HEAD
  run git push origin "refs/tags/$tag" --force
fi

notes="$tmpdir/release-notes.md"
write_release_notes "$checksum" "$notes"
run gh release edit "$tag" \
  --repo robzilla1738/harness-terminal \
  --target "$(git rev-parse HEAD)" \
  --title "$release_name" \
  --notes-file "$notes" \
  --latest

echo
echo "Release complete:"
echo "  $release_name"
echo "  DMG SHA-256: $checksum"
echo "  https://github.com/robzilla1738/harness-terminal/releases/tag/$tag"
