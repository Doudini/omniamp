#!/bin/zsh
# Build dist/OmniAmp-<version>.dmg for sharing, without an Apple Developer account.
#
#   ./scripts/make-dmg.sh [version]          e.g. ./scripts/make-dmg.sh 0.2
#
# The app is signed ad-hoc (not notarized), so macOS blocks it the first time; the DMG includes a short
# "How to open" note (System Settings → Privacy & Security → Open Anyway).
#
# Last.fm: the app's API key and secret from secrets.env are built in, so scrobbling works out of the box.
# A desktop app can't keep them truly secret (every scrobbler ships them; they only identify the app, users
# still approve access to their own account), so use a dedicated "OmniAmp" API account. If it's ever abused,
# make a new one and ship an update; users can also enter their own key in Settings.
# OMNIAMP_DMG_NO_SECRETS=1 leaves the key out.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}
VERSION=${VERSION:-0.1}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

STAGE=$(mktemp -d)/OmniAmp
mkdir -p "$STAGE" dist
# Built straight into the staging folder, so the OmniAmp.app next to Package.swift (with your keys) is untouched.
if [[ -n "${OMNIAMP_DMG_NO_SECRETS:-}" ]]; then
  OMNIAMP_APP_PATH="$STAGE/OmniAmp.app" OMNIAMP_NO_SECRETS=1 OMNIAMP_VERSION=$VERSION OMNIAMP_BUILD=$BUILD ./scripts/make-app.sh
else
  [[ -f secrets.env ]] || echo "Note: no secrets.env, so this DMG has no built-in Last.fm key (users can add their own)." >&2
  OMNIAMP_APP_PATH="$STAGE/OmniAmp.app" OMNIAMP_VERSION=$VERSION OMNIAMP_BUILD=$BUILD ./scripts/make-app.sh
fi
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to open OmniAmp.txt" <<'TXT'
OmniAmp
=======

1. Drag OmniAmp into the Applications folder.

2. Open it once. macOS says it can't check it for malicious software: OmniAmp is free and
   open source, but not signed with a paid Apple Developer certificate. Click "Done"
   (not "Move to Bin").

3. Open System Settings → Privacy & Security, scroll down to the message about OmniAmp
   and click "Open Anyway". Confirm with your password or Touch ID.

   From then on OmniAmp opens normally.

Prefer the Terminal? This does steps 2–3 in one go:

   xattr -dr com.apple.quarantine /Applications/OmniAmp.app

Source code and issues: https://github.com/Doudini/omniamp
TXT

DMG="dist/OmniAmp-$VERSION.dmg"
rm -f "$DMG"
LOG=$(mktemp)
if ! hdiutil create -volname "OmniAmp $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >"$LOG" 2>&1; then
  cat "$LOG" >&2; rm -f "$LOG"; echo "Creating the DMG failed." >&2; exit 1
fi
grep -v deprecated "$LOG" >&2 || true   # hdiutil's own "deprecated" notices aren't worth showing
rm -f "$LOG"
rm -rf "$(dirname "$STAGE")"
echo "Built $PWD/$DMG ($(du -h "$DMG" | cut -f1))"
