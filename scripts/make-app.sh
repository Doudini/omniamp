#!/bin/zsh
# Build a release OmniAmp.app next to Package.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=OmniAmp.app
# Optional, never committed: secrets.env with LASTFM_API_KEY=… and LASTFM_SECRET=… (see README).
LASTFM_API_KEY=""; LASTFM_SECRET=""
[[ -f secrets.env ]] && source secrets.env
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/OmniAmp" "$APP/Contents/MacOS/OmniAmp"
# App icon: compile the Icon Composer icon (a macOS 26+ style icon, full size, no grey "legacy" plate) when
# Xcode's actool is around; otherwise ship the prebuilt AppIcon.icns (also made by actool, via scripts/make-icon.sh).
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist /dev/null >/dev/null
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Built-in classic skin: Winamp 2.91's base skin.
mkdir -p "$APP/Contents/Resources/Skins"
cp Resources/base-2.91.wsz "$APP/Contents/Resources/Skins/"
mkdir -p "$APP/Contents/Resources/Fonts"
# Ship TTF, not WOFF2: TTFs are memory-mapped, WOFF2s get decompressed into RAM (~16 MB each).
CONVERTER=.build/woff2-to-ttf
if [[ ! -x $CONVERTER || scripts/woff2-to-ttf.swift -nt $CONVERTER ]]; then swiftc -O -o $CONVERTER scripts/woff2-to-ttf.swift; fi
$CONVERTER fonts/HackNerdFont-Regular.woff2 fonts/HackNerdFont-Bold.woff2 "$APP/Contents/Resources/Fonts" >/dev/null
cp fonts/LICENSE-Hack.md fonts/LICENSE-NerdFonts.txt "$APP/Contents/Resources/Fonts/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>OmniAmp</string>
  <key>CFBundleDisplayName</key><string>OmniAmp</string>
  <key>CFBundleIdentifier</key><string>com.microbot.omniamp</string>
  <key>CFBundleExecutable</key><string>OmniAmp</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>LastFMAPIKey</key><string>${LASTFM_API_KEY}</string>
  <key>LastFMSecret</key><string>${LASTFM_SECRET}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <!-- Internet radio: many stations only stream over plain http. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Audio</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array><string>public.mp3</string><string>org.xiph.flac</string><string>public.folder</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Winamp Skin</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>CFBundleTypeExtensions</key><array><string>wsz</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
# The bundle was deleted and recreated: make Finder and the Dock drop the cached (placeholder) icon.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true
echo "Built $PWD/$APP"
