#!/bin/bash
# Crea "GZ Brain.app" dalla build release e la installa in /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="GZ Brain"
BUNDLE="build/$APP_NAME.app"
ICON_SRC="${ICON_SRC:-$(pwd)/AppIconSource.png}"

swift build -c release

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp .build/release/HubProto "$BUNDLE/Contents/MacOS/$APP_NAME"

# script proxy per la Preview locale (Code → Preview): va nelle Resources del bundle
if [ -f scripts/preview-proxy.mjs ]; then
  cp scripts/preview-proxy.mjs "$BUNDLE/Contents/Resources/"
fi

# icona da icon-source.png (stessa della versione Tauri)
if [ -f "$ICON_SRC" ]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for sz in 16 32 64 128 256 512 1024; do
    sips -z $sz $sz "$ICON_SRC" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  done
  cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
  cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
  cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
  cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
  cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
  rm "$ICONSET/icon_64x64.png" "$ICONSET/icon_1024x1024.png"
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>dev.gz.brain</string>
  <key>CFBundleVersion</key><string>0.1.0</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- Senza queste righe macOS non chiede il permesso e nei pannelli «apri file»
       Scrivania, Documenti e Download compaiono vuoti: le foto da caricare
       sembrano sparite. Il testo è quello che si legge nella richiesta. -->
  <key>NSDesktopFolderUsageDescription</key><string>Per scegliere le foto e i documenti degli immobili salvati sulla Scrivania.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Per scegliere le foto e i documenti degli immobili salvati in Documenti.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Per scegliere le foto e i documenti degli immobili appena scaricati.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Per caricare foto e documenti da chiavette e dischi esterni.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$BUNDLE"
rm -rf "/Applications/$APP_NAME.app"
cp -R "$BUNDLE" /Applications/
echo "✓ installata: /Applications/$APP_NAME.app"
