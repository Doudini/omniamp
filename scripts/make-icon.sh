#!/bin/zsh
# Rebuilds the fallback Resources/AppIcon.icns from Resources/AppIcon.icon (edit icon.json / omniamp.svg, then run this).
# make-app.sh compiles the .icon itself when Xcode is installed; the .icns is for builds without Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$OUT" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist /dev/null >/dev/null
cp "$OUT/AppIcon.icns" Resources/AppIcon.icns
rm -rf "$OUT"
echo "wrote Resources/AppIcon.icns"
