#!/bin/zsh
# Build a release OmniAmp.app next to Package.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=OmniAmp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/OmniAmp" "$APP/Contents/MacOS/OmniAmp"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
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
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
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
echo "Built $PWD/$APP"
