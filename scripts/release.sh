#!/bin/zsh
# Publish a new version on GitHub Releases, where OmniAmp → Check for Updates… looks.
#
#   ./scripts/release.sh 0.3 [notes.md]
#
# Builds dist/OmniAmp-<version>.dmg (signed with the OmniAmp certificate if you have it), tags v<version> on
# the current commit and publishes the release with the DMG. Without a notes file, the notes list the commits
# since the previous release.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: release.sh <version> [notes.md]}
NOTES=${2:-}
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
git fetch -q origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse @{u})" ]] || { echo "Push your commits first (the release is tagged on what's on GitHub)." >&2; exit 1; }
# Check for Updates only installs builds signed with the OmniAmp certificate: an ad-hoc build published
# here would be refused by everyone's updater, so don't publish one.
security find-identity -p codesigning 2>/dev/null | grep -q '"OmniAmp Code Signing"' ||
  { echo "No \"OmniAmp Code Signing\" certificate in the Keychain (see README → Signing)." >&2; exit 1; }

./scripts/make-dmg.sh "$VERSION"
DMG="dist/OmniAmp-$VERSION.dmg"

# The same check the updater makes (Updater.swift): the app in the DMG must satisfy OmniAmp's requirement.
MNT=$(mktemp -d)
hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
trap 'hdiutil detach -quiet "$MNT" 2>/dev/null || true' EXIT
REQ='identifier "com.microbot.omniamp" and certificate root = H"4acac334c056879abebe11fc6caa607f1a91800c"'
codesign --verify --deep --strict -R="$REQ" "$MNT/OmniAmp.app" ||
  { echo "The DMG's app doesn't pass the updater's signature check; not publishing." >&2; exit 1; }
hdiutil detach -quiet "$MNT"; trap - EXIT

if [[ -z "$NOTES" ]]; then
  NOTES=$(mktemp)
  PREV=$(git describe --tags --abbrev=0 2>/dev/null || true)
  { echo "## Changes"; echo
    git log --no-merges --format='- %s' ${PREV:+$PREV..}HEAD
    echo; echo "Update from inside OmniAmp: **OmniAmp → Check for Updates…**, or download the DMG below."
    echo; echo "SHA-256: \`$(shasum -a 256 "$DMG" | cut -d' ' -f1)\`"; } > "$NOTES"
fi
gh release create "v$VERSION" "$DMG" --target "$(git rev-parse HEAD)" --title "OmniAmp $VERSION" --notes-file "$NOTES"
